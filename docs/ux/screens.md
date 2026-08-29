# UX — Screens

Every screen, its purpose, its states, and the navigation between them. Screens are SwiftUI,
MVVM, `@MainActor` view models fed by the live-feed reader and the `FlowStore` (see
[`../spec/persistence.md`](../spec/persistence.md), [`../spec/ipc.md`](../spec/ipc.md)).

## Navigation map

```
Onboarding (first run only)
        │
        ▼
   TabView
   ├─ Dashboard ──▶ Flow Inspector
   ├─ Timeline  ──▶ Flow Inspector ──▶ Packet detail
   ├─ Captures  ──▶ Share (.pcap / JSON)
   └─ Settings  ──▶ TLS inspection setup (CA flow)
                 ├─ Storage
                 ├─ Introduction ──▶ Onboarding (replayed on demand)
                 ├─ Session diagnostics
                 └─ About / privacy
```

The onboarding is not a one-way door: Settings can bring it back, which is what makes skipping it
safe (see [`onboarding-and-consent.md`](onboarding-and-consent.md)).

## Dashboard
**Purpose:** at-a-glance live view + one-tap monitoring control.

- **Monitoring control:** big, unambiguous Start/Stop with current state; mirrors the system
  VPN indicator.
- **Throughput chart:** real-time in/out (Swift Charts), rolling window; VoiceOver reads
  current rates.
- **Top talkers:** the busiest hosts/apps right now, by bytes, tappable → Flow Inspector.
- **At-a-glance counters:** active flows, data used this session, dropped-records indicator
  (honest, subtle) when back-pressure is active.
- **States:** `off` (invite to start) · `starting` · `live` · `error` (actionable).

**Fixed (2026-08-18): the monitoring control now weighs what it is worth in each state.** "Big,
unambiguous" is what this page asked for and what M9 built, and the finished screen showed it had gone
too far — the block took about half the Dashboard even with the tunnel on, which is when the chart,
the counters and the top talkers are what the screen is *for*. The control has **two forms** now and
the choice is a value, not a view detail (`MonitoringProminence`): a **card** whenever there is
something to offer — `off`, first run, and every failure — and a one-line **status strip** while the
tunnel is running or moving. Nothing was taken away to get there: the strip keeps the headline, the
promise underneath it (*everything stays on this device*, which is exactly the sentence that matters
while monitoring is on) and the stop action. What survived the rework, because it had to: the four
states are still told apart without colour — `live` gets a **closed** shield, since in the strip the
symbol has no prose beside it — and the control still works at accessibility sizes, where the button
drops below the headline and takes the width.

Two defects came out of measuring it rather than looking at it, both now fixed. The primary button's
`.frame(maxWidth: .infinity)` sat on the **button** and not on its label, so the fill stayed a narrow
pill in the middle of the card and only the pill was tappable — the same defect the intro paid for.
And the strip's own button measured **34 pt** tall against the HIG's 44 (`idb ui describe-all` reports
the frame a finger really gets); the minimum is a token now (`TouchTarget.minimum`).

**And the counters got a heading.** *Received* and *Sent* appeared twice in a row on this screen — as
a per-second rate inside the chart and as a session total in the tiles — with nothing saying which was
which. The tiles sit under *This session* now, so the screen reads as two named groups of data around
a chart that speaks for itself.

## Timeline
**Purpose:** scrollable history of connections.

- Reverse-chronological list of flows; each row: host/SNI, app hint, ports, bytes, duration, a
  TLS-status badge (`plaintext` / `encrypted` / `inspected` / `not inspectable` — icon + label
  + color, never color alone).
- **Filter/search:** by host, protocol, TLS status, time range.
- **Interactive scrub:** a mini time axis to jump to a moment; taps open the Flow Inspector.
- **Performance:** paginated through `HistoryReader` (cursor over the store's `recentFlows`), lazy
  rows; smooth with tens of thousands of flows.
- **States:** `empty` (teach) · `loading older` · `populated`.

**The two defects Juan found in the scrub row using the app (2026-08-18) — both fixed (2026-08-19).**
They were about the first row of the list, the *Activity for everything recorded* card, and neither
fix undoes the trap already paid for: at accessibility text sizes the axis still **stops being pinned**
and becomes the first row, because a pinned band eats the viewport (`design-system.md`).

1. **The large title and the search field ran straight through it.** As the list's first row the axis
   scrolls under the navigation bar, and iOS 26 draws that bar as glass — so the axis's caption read
   *through* the title. The fix is the one the diagnosis implies: give the bar something opaque
   (`.toolbarBackground(.visible, …)` in the canvas colour). Looking at it also found why this screen
   had no large title at all — `.navigationBarDrawer(displayMode: .always)` costs it — and dropping
   the placement brings the title back.
2. **An interval was 14 pt wide.** Picking one is the whole point of the axis, so an interval is a
   touch target and owes the 44 pt minimum. Intervals tile the axis and cannot be padded apart, so the
   fix is to offer **fewer**: how many the axis offers now follows the **screen's width** (measured in
   the view, decided by `ScrubCapacity`, applied by `HistoryReader.setAxisCapacity` — `axisBars` is its
   ceiling). The resolution that costs is bought back by the gesture the axis already had, tapping a
   bar to zoom into it, and the rail is twice the touch minimum tall so the gesture has room vertically
   too. The axis also **dropped its in-chart labels** at every text size — the space they reserved was
   almost two intervals wide, and the caption row underneath already dates both ends better —, and the
   ladder of round bucket widths gained its intermediate rungs so a small bar count still yields an
   axis with a shape. `ScrubAccessibility` is untouched: what a finger applies and what VoiceOver
   applies still come from the same place.

**The second pass reached the rows themselves (2026-08-19).** They were three lines of equal weight
with a full encryption badge in the middle one, and on an ordinary history that badge said *Encrypted*
on every row — the most contrasted thing in the row spent repeating what the list already assumes, so
the eye landed on the least informative datum. Now the row is a **rail and three lines**: the status as
a coloured **mark** in a leading column, then the host with its time, what the connection was, and what
it moved. Only a **departure** from the assumption writes its name (*Not encrypted*, *Inspected*, *Kept
private*), which is decided in the pure layer (`TLSStatusPresentation.emphasis`, no default) and not by
the view; the capsule stays in the Flow Inspector, where it heads the file on one connection. Nothing
left the row — host, time, state, protocol, port, both byte figures and the duration are all still
there — and it is **86 pt** tall instead of 102, one more connection per screen. Three smaller
decisions came with it: the three figures are spread as **equal columns** so they line up down the
list (the only part of the row read by comparing, so the only part drawn as a table), the clock beside
the duration is gone because an icon that only repeats its own value is decoration two hundred times
over, and the figures and the time are set in the figure role the packet list already uses. The
arrows stay: they are the only thing separating received from sent without spending two words a row.

**As implemented (M9):** rows, filters, pagination, the scrub bar and the states are in. One
deviation, deliberate: **search applies on submit** (and on clearing the field) rather than on every
keystroke — the text is matched against the host shown, which the reader resolves in memory over
chained store pages, so a search per letter spends disk reads on lists nobody reads.

**The scrub bar** sits above the list and is a time axis over the history — packets per interval,
zero-filled, from a new aggregate query in the store rather than the cursor pagination the list uses.
Tapping an interval filters the list to it and, if there is anything inside to look at, **redraws the
axis within it**; tapping what is already picked releases it. Four things it decides. **(1) A tapped
interval is absolute and is never recomputed.** The menu's ranges are rules
("last hour" must mean the hour before *now*, so it is re-evaluated on every reload); an interval
picked off the axis is the opposite — a specific slice of the past — and putting it through the same
recomputation would move it under the user's finger. They are two different things and
`TimelineDateFilter` says so. **(2) With an interval picked, no preset is ticked** in the menu:
leaving "Any time" ticked would claim the list is unbounded. **(3) The axis honours no filter, and
says so under the bar.** Its counts cover everything recorded, including connections the list is
hiding — the host filter is resolved in memory, so it cannot be pushed into the query that
aggregates, and honouring half the criteria would look filtered without being it. **(4) Without any
history the bar is not drawn at all**, because an axis flat at zero reads as "no traffic in all this
time" rather than "nothing recorded yet", and the latter is what the empty list already says.

**Zooming in** is what keeps the axis usable once there are weeks recorded: at that scale every bar is
hours wide, and "jump to a moment" would mean jumping to a Tuesday afternoon. Four more decisions.
**(1) Filtering and zooming are the same gesture.** Separating them would leave two things set at once
— what the list shows and what the axis covers — that would need explaining separately, and the moment
they disagreed the bar would stop saying what is being looked at. Being one, there is a single answer
to "where am I": the foot of the bar. **(2) The way out mirrors the way in.** One enters by tapping
ever finer stretches, so one leaves by undoing that path: *Back* goes up a level and takes the list
with it, and past the first level *All* returns to the whole history at once (with one level down,
*Back* already lands there, and two buttons for the same destination read as two destinations). No
stretch is a dead end — the rule from [`00-ux-principles.md`](00-ux-principles.md). **(3) A stretch
with nothing inside is not entered.** An empty bar hides no traffic (the gaps are zero-filled), and one
already at the finest rung cannot be subdivided; tapping either filters the list and highlights it,
which is what the bar did before zooming existed. **(4) Retention winning the stretch is said out
loud.** If the slice being viewed is no longer stored, the axis cannot be drawn flat at zero — that
reads as "no traffic here" — so it returns to the whole history, releases the stretch that was
bounding the list, and says why. An axis that jumps somewhere else without explaining itself reads as
a failure, not as an exit. Zoomed in, the note under the bar stops claiming the counts cover
everything recorded and says they are for this stretch — still unfiltered, just no longer everything.

**Sweeping across bars** is the other half of "jump to a moment", and the one the tap cannot cover: to
bound an hour drawn in fifteen-minute bars you would have to tap the fifteen, not sweep the four.
Dragging across the axis bounds the list to everything swept. Four decisions. **(1) A swept stretch
does not zoom.** It is not a bar, so entering it would stack a level matching nothing drawn and *Back*
would return to a place nobody picked. Tapping picks where the axis looks; sweeping picks how much the
list shows, and inside a zoomed axis the two compose — the stretch stays, the list narrows, and
*Clear* returns the list to what the axis is showing. **(2) It snaps to whole bars.** A stretch
starting mid-bar would leave that bar highlighted whole while the list hides part of what it counts,
and the foot of the bar would date something that matches nothing drawn. **(3) A finger that enters or
leaves through the edge is clamped to the edge**, not ignored: unlike a tap outside the axis — which
points at nothing and is dropped — a drag that runs off the side is heading somewhere, and end to end
is exactly how one asks for all of it. **(4) The list is filtered on release**, and until then the bar
is a live readout of what is about to be bounded: it dates the swept stretch and highlights every bar
in it, with no *Clear* offered, because there is nothing set yet to clear. Filtering per frame would
be a history query per pixel travelled.

**Without sight, the axis is a cursor** (M11). It is one accessibility element — reading it bar by bar
would recite dozens of counts with no shape — so neither of its two gestures can be performed: there
is no way to say *which* interval, let alone *from where to where*. What replaces them is a focused
interval that moves one step at a time, whose reading is the axis's only moving part (when the
interval is, how much traffic it carried, and where it falls: *Interval 4 of 6*, without which
swiping through similar bars gives no way to tell one is moving at all). Four decisions.
**(1) Activating always means "apply what I have chosen"** — the focused interval on its own, exactly
as tapping it, or the stretch between the two ends if one has been fixed. One rule rather than two
buttons, so the default gesture never means something other than what was just announced.
**(2) Sweeping becomes two ends and not a second cursor:** fixing one end and then moving extends the
choice, which is what a finger that has not been lifted does. **(3) A reloaded axis releases a
selection in progress but keeps the cursor's place.** Bars re-align when the history grows or
retention cuts, so a fixed end may have come to point at a different slice of the past and applying it
would bound the list to something nobody picked; losing your place, on the other hand, is worse than
standing near where you were. **(4) The stretch is rounded by the same `ActivityAxis.sweep` the drag
uses**, with each end given as the *centre* of its bar: the axis's intervals touch, so a bar's opening
instant belongs to the previous one too, and choosing "from this one" would quietly drag in its
neighbour. The total moved from the element's value to its **label**, since the value is what changes
as the axis is walked, and the zoom promise moved to its **hint**.

Rows became tappable when the Flow Inspector landed; until then they were
not, because a row that leads nowhere is worse than a row that does not invite the tap. The three empties
(`loading`, "no connections yet", "no matches" with a *clear filters* action) and the error card come
from one pure function, `TimelinePresentation.content`, whose first rule is that a list already drawn
is never covered — a failure while paginating goes to the footer instead.

## Flow Inspector
**Purpose:** everything about one connection.

- Header: 5-tuple in human terms (host, ports), protocol, duration, bytes in/out, TLS status.
- If `plaintext`/`inspected`: the decoded request/response (headers, and body per capture
  detail); pretty-print JSON; clearly mark inspected content.
- If `encrypted`/`not inspectable`: explain why ("this app pins its certificate; its content
  stays private") — turn a limitation into a trust signal.
- Packet list for the flow → **Packet detail** (per-packet timing, flags, length; jump into the
  pcap bytes via the packet's `CaptureLocation`).
- Actions: export this flow, copy host, block/allow (firewall) toggle.

**As implemented (M9):** the header, the encryption explanation and the packet list are in; a row of the
Timeline opens the screen. Four deviations, all deliberate. **Flags are not shown as flags:** every packet
is titled by what it *meant* for the connection — opened, accepted, data, delivery confirmed, finished
sending, cut off — and the acronyms sit under it in tertiary text, for whoever reads them. `RST` outranks
every other flag when classifying, because it arrives with `ACK` set almost every time and reading that
packet as a confirmation would hide the only thing worth telling. **Times are relative to the connection's
first packet** (`0.004 s`), with millisecond resolution: an absolute clock time says nothing about where a
packet sat in what happened. **A capped list says so** — `HistoryPolicy.packetsPerFlow` is 500, and if the
flow counted more, the footer names both numbers. **Added in M8 (2026-08-13) — the *Decrypted content* section.** Between the encryption block and the
packet list, because what could be seen of the contents only makes sense under the explanation of
whether it was encrypted at all. It either leads to the conversation — one row saying **how much was
saved**, not how many turns, since the amount is what tells the user whether it is worth opening — or
tells apart the **four** ways of having nothing, each of which asserts a different thing: it was not
encrypted (what travelled is in the packets below), it was not inspected, the app on the other end pins
its certificate (written as a guarantee, not a limitation — ADR 0003), or it was inspected and nothing
was kept (the separate switch is off, or what was kept has expired). **None of the four offers a
button**: three of them are changed in Settings, after installing a certificate, and nudging from here
would turn an explanation into bait. And the section **does not exist until its index has been read**,
because all four assert something and none is true before asking.

**What the second design pass changed (2026-08-20).** The header is **six facts and not seven**, and
both halves of that came from looking at the screen rather than from a rule. *Started* and *Last packet*
were the two ends of one span sitting in **different rows and different columns** — the beginning top
right, the end bottom left — so an interval had to be read diagonally; they are one fact now (*First to
last packet*), still deliberately not *Started* / *Ended*, because a connection whose packets stopped may
still be open and the app cannot tell. And with the seventh gone, the **orphan row** at the foot of a
two-column grid went with it: the grid fills without anything being padded. The pairs carry meaning now —
what it was next to when it happened, how long next to how many packets, and the two directions **side by
side**, which is the one comparison the header is asked for. The grid also **lost its icons** (see
[`design-system.md`](design-system.md)), and the *Decrypted content* section's four absences stopped
being a card: an explanation with nothing to open is a note under its heading, not a row. The header card
gave back 70 pt and the packet list starts **94 pt higher** — one more packet visible without scrolling.

**Still not built:** the export / copy / block actions.

## Decrypted content
**Purpose:** what was said inside one inspected connection, in the order it was said.

Reached from the Flow Inspector's *Decrypted content* section. It is its own screen rather than another
section because what is answered at a glance is *whether* there is anything — the section says that —
and what was said is a long list that needs the full width.

**As implemented (M8, 2026-08-13):** three decisions, and none of them about bytes.

**A turn is a maximal run of consecutive chunks in the same direction**, and the only boundary is the
change of side. A chunk is not a turn: the termination emits them as they arrive from its two legs, so
drawing them one by one would show the rhythm of socket reads instead of the conversation's. Splitting
on a time gap too was considered and rejected — the threshold would be an invented number, and a slow
reply is still one reply.

**About what did not fit, only what is known is said.** Of the turn, both exact figures; and that from
it onward that side stopped being recorded, which follows with no figure at all because the recording
budget cuts before writing and so leaves the truncated chunk last. **There is no per-connection total,
and that absence is the decision**: the only figure derivable today is a lower bound, and a lower bound
presented as a total is a lie.

**Sharing is offered, one turn at a time and never the whole conversation**, and it hands over the whole
turn rather than the preview: the screen draws about a kilobyte so a turn can be read at a glance, and a
turn reaches 64 KiB, so sharing what is drawn would leave the rest on the device and out of its owner's
reach. The text body is also selectable, so copying one header line needs no share sheet at all.

**Not drawn as chat bubbles.** Aligning one side right gives away half the width, and what is read here
is often a hex dump or an HTTP header block, which need the whole line and columns that line up. Who
spoke is carried by the header — the direction icon and word the whole app uses, plus how far into the
connection it happened — which is how every other list in this product says it. The body is text when
it decodes as UTF-8 (tolerating the character the cut split at the end) and carries no control bytes
beyond tab and newlines; otherwise a hex dump, capped shorter than text because a dump line holds
sixteen bytes and a text line seventy.

## Packet detail
**Purpose:** one packet, down to its bytes.

Reached by tapping any row of the Flow Inspector's packet list. It shows what the packet meant, the
facts that need no file open (when it happened inside the connection, direction, size, flags), and the
raw bytes of the record as hex + ASCII — the bare IP datagram, exactly as it travelled.

**As implemented (M9):** the jump `CaptureLocation` was built for. `PcapFormat` moved to `Shared` so
that writing a header and parsing it are one truth, and `CaptureLibrary.record(at:)` opens the file at
the packet's offset — three short seeks, never a scan, with `incl_len` bounded against the file's
`snaplen` before anything is allocated, because a 64 MB capture must not be read to show one packet.
Four decisions. **Every row leads here, including a packet whose bytes were never captured:** the screen
explains why there are none, and a list where only some rows answer the tap gives the user no way to
tell which. **The bytes are drawn only if the record describes *this* packet** (its `orig_len` against
the stored length) — showing the wrong record would be another connection's traffic on this screen, the
one thing the file+offset pair exists to prevent. **A deleted capture is not a breakage:** it reads as
"those bytes are gone, the connection stays in your history", with no retry, because retrying cannot
bring back a file its owner removed — only a genuine read failure offers to try again. **Showing less
than the whole packet is said out loud, and the two reasons are counted apart:** what the `snaplen` cut
when capturing (permanent) and what the screen caps when drawing (2 KB, cosmetic).

**And since M11 the screen reads those bytes instead of only showing them** — a *Headers* grid above the
dump, named field by field, for whoever does not know where the destination port starts. It says the two
layers, the two ends and what only that protocol has, and it deliberately repeats nothing the stored
metadata already says.

**Since 2026-08-22 the grid goes one layer further, and DNS is the first** (roadmap step 10). A datagram
on port 53 also says what kind of message it is, what name was looked up, of what record type, and — on a
reply — what it answered: the addresses it resolved to, the name it resolved to, how many records of a
kind this app does not break down, or that it answered nothing and why (*No such name* and *No records of
that type* are different answers and are never said the same way). It needs no new screen: the fields
land in the grid the aesthetic pass left able to take more, in an order that puts *Looked up* and *Record
type* in one row. A port-53 datagram whose message cannot be read **says so** rather than quietly
dropping the fields, in the same two wordings the headers themselves use — the capture kept too little
(Settings can change it) or those bytes are not a DNS message (nothing can).

## Captures
**Purpose:** manage and export `.pcap` files.

- List of capture files with size/time; total storage used.
- Actions: share (`.pcap` via share sheet → Wireshark/tcpdump), export flow list as JSON,
  delete, and rotate (start a new file).
- **States:** `empty` · `list` · `exporting`.

**As implemented (M9):** the list (newest first, with size and time), the total in the footer, share,
delete, rotate and the JSON export of the connection list are in, over `CaptureLibrary` and
`FlowExporter`. Four deviations, all deliberate.
**The file being written is marked "Recording" and can be neither shared nor deleted:** its last bytes
can be a half-written record, and deleting it would leave the extension writing into a file with no
name — no error, and nothing left to export. The way out is offered rather than the refusal alone, and
it is the one the control channel was built for: *New capture file* closes the current one so it can be
exported without stopping monitoring. Which file that is gets **derived** — the highest sequence in the
directory, and only while the tunnel is live — because with the tunnel stopped nothing is open, however
recent the last file. **Deleting says what is lost before it happens:** the connections recorded while
the file was being written stay in the history; only the raw bytes go, and they do not come back.
**Sharing a `.pcap` has no `exporting` state:** `ShareLink` *is* the system sheet and the file is
already on disk, so there is nothing to prepare. The packet→bytes jump that used to be listed here
landed with *Packet detail* above, over this screen's own service.

**The row, after the second aesthetic pass (2026-08-20):** the name and the **size** share the headline
— the size at its trailing edge, in `rowFigure`, so the three figures fall on one vertical and the
inventory can be read by comparing — and the time sits alone underneath. They used to be one grey line
joined by a `·`, which set this screen's only figure as prose. The share control owes 44 pt like
anything else a finger lands on (it offered **18 × 21**), and the trailing slot keeps that width even
on the row that has no action, so the open file's size does not step out of the column. The row is
**one** accessibility element followed by its button; it was three, and the tree's positional order put
the button between the name and its own detail. At accessibility sizes the row stacks and the share
control takes its word, because a bare glyph at the leading margin has nothing left to explain it.
There is deliberately **no leading rail** as on the Timeline: with one assumption and one exception a
mark on every row would only say *this is a capture file*.

**Room left (2026-08-23):** the screen now answers the question it used to leave open — *is this
going to fill my phone?* — in the two thirds of the screen that sat empty under the inventory (373 of
an iPhone 17's 874 points, measured). The two halves already existed and did not speak to each other:
this screen knew what the captures occupy, Settings knew the ceilings they may grow to and how long
they are kept, and the comparison — which is the actual answer — was left to the user's eye, with the
two figures on **different screens**. `CaptureHeadroom` makes it, from the same `RetentionPlanner`
the cleanup uses, so what the screen promises and what later happens cannot differ.

It leads with the figure that answers: **how much room is left**, then the bar that draws the same
proportion, then the raw figures under it, and last — as the section's footer — what happens when the
limit is reached. Four size outcomes and four expiry outcomes, none of them collapsed, all pure and
without a default: room to spare, the limit already full (which is *not* `within` with zero left: what
is left to say there is that something will be lost), a limit that **cannot be met** because the open
capture alone is over it, and no size limit at all. And for the expiry: a date, a count of the ones
already past it, no date yet — a capture file keeps growing until the next one opens, so until then
there is nothing to count its age from — and an expiry the user turned off. **Neither limit set is its
own case**, not the sum of the two "no limit" halves: two halves each denying its own ceiling would
make the user join two negatives to reach the only sentence that matters, which is that nothing removes
a capture unless they do.

**And the footer of the inventory stopped repeating the size** (`3 captures · 6.7 MB` → `3 captures`).
A fact is said once, and the place a size is said is beside the ceiling it is compared against — the
same line along which `StorageFigure` splits its two figures in Settings. Limits that cannot be read
hide the comparison and say so, rather than filling it in with factory values: that would state a
ceiling the user may have changed, and the whole answer hangs off it.

**The connection list as JSON (M9):** the `exporting` state above is real for this one and only this
one — the file has to be written before it can be shared. Five decisions.
**What travels is metadata, never payloads:** the five-tuple in human terms, the times, the bytes per
direction, the packet count and the encryption status. The history stores packet metadata and not
bytes, so an export that promised content would be lying about what the product does — and the raw
bytes already have their format and their place, the `.pcap` on this same screen.
**What slice gets exported is said on the button, not in the small print:** this screen has no history
filter, so what comes out is the whole history, and the button says *Export all connections*. A
history longer than the cap (20,000 connections) exports the most recent ones and the file says
`truncated`, as does the screen.
**Nothing leaves the device before the user is told what is in it:** preparing the file does not share
it. A sheet says how many connections it holds, how big it is and that it carries no packet contents,
and only then offers the system share sheet — the same "explain first, never after" rule as the VPN
permission.
**It is written in pieces and the counts go in the trailer.** A history of tens of thousands of rows is
not built in memory as one blob; the connection count and the truncation flag are only known at the
end, and in a JSON object key order means nothing, so saying it last costs nothing and saying it first
would cost another pass over the history.
**The file is the app's, and the app cleans it up:** it lives in the app's temporary directory (not
among the captures, where it would show up in this listing and in the retention plans), and each
export clears the previous one, so at most one copy of the history sits there. A failure halfway
deletes the half-written file: an unterminated JSON does not read as an error, it reads as a history
that ends early.

## Settings
- **Look inside secure traffic (TLS inspection):** off by default; entry to the CA flow in
  [`onboarding-and-consent.md`](onboarding-and-consent.md); shows current trust status and how
  to remove it.
- **Capture detail:** metadata-only ↔ full payload; explains battery/storage impact.
- **UDP/streaming passthrough:** on by default (battery); explained plainly.
- **Storage:** retention cap (size/age), current usage, prune/clear now.
- **About / privacy:** the on-device, no-cloud promise, in plain words; links to how VPN and
  certificate trust work.

**As implemented (M9):** the screen is in, over `AppSettings` + `SettingsStore` (where a choice is kept
— the durable truth the extension reads when it starts a session, next to the control channel that
applies a change to a session already running) and `StorageManager` (retention, which had been the
largest loose end in the project: nothing capped the capture directory, so it grew for as long as
monitoring ran). Editing a setting is *read, change one field, save the whole `AppSettings`*, and three
rules shape everything on the screen.

**Saved first, applied to the live session second.** What is durable is the store: a control-channel
command lost in a race with `stopTunnel` cannot be allowed to leave the choice unsaved, while the
reverse only costs the change reaching the session in progress — and that gets said out loud. **A
setting that could not be saved goes back to what it was**, because leaving the switch in its new
position would claim a write that did not happen. And **nothing is deleted without knowing which file
is being recorded**: that is derived from the directory listing with the same single function the
Captures screen uses (`CapturesPresentation.recordingSequence`), so if the listing fails while
monitoring runs, the screen refuses to delete rather than risk taking the open file with it.

Four things the screen says that are not obvious. **Retention cuts both halves or it lies:** pruning
rows leaves the `.pcap` files on disk, deleting files leaves the history pointing at bytes that are
gone, so one service does both — and the size cap governs the captures only, because SQLite does not
give space back when rows are deleted and a cap that cannot be enforced is worse than no cap. The
screen also says that plainly, and that the history figure does not drop right after a cleanup for the
same reason. **The caps are applied when the screen opens and whenever one is changed**, not only from
*Apply limits now*: retention is the app's job, so nobody enforces it while the app is closed, and a
cap that waits for a button is not a cap. An automatic pass that found nothing to delete stays silent;
anything the user asked for always answers. **The file being recorded is never deleted**, by retention
or by *Delete everything*, for the same reason the Captures screen refuses to: the way out is *New
capture file*. **Capture detail applies the next time monitoring starts.** The `snaplen` lives in the
`.pcap` file header, so it belongs to the file and not to the record, and the session's writer was
created with the previous one — rotating would not change it either, since the new file inherits the
session's `snaplen`. Saying when it starts to apply is honest; offering a rotation that does not apply
it would not be.

**Two deviations from the list above, both deliberate.** The **TLS-inspection switch is present but
cannot be turned on**: enabling it requires a certificate the user generates and installs themselves,
and that guided flow is M10 ([`onboarding-and-consent.md`](onboarding-and-consent.md)) — the saved
setting cannot assert on its own that the CA is ready, so the screen asks for that fact separately and
today the honest answer is "not yet". It can always be turned **off**, whatever that answer says, or
the feature would be irreversible in practice. And there is **no *UDP/streaming passthrough* toggle**:
the pipeline already routes UDP to passthrough always, so the switch would have nothing to turn off and
could only mislead. **Not built yet:** export of captures from this screen — the `.pcap` is shared from
Captures.

**Added in M10 — the row that opens the CA flow.** The switch now sits above a row that pushes the
guided setup ([`onboarding-and-consent.md`](onboarding-and-consent.md)), and it is there whatever the
answer about the certificate is: it is also where the certificate is remade and where it is removed,
which is the half of the reversibility a switch cannot hold. Its label is the only thing the screen
says about the certificate's state, and it says no more than it knows — *Set up secure traffic
inspection* while inspection cannot be turned on (which does not distinguish "no certificate" from "not
trusted yet", because iOS does not), *Manage your certificate* once it can. **Coming back from the flow
re-reads everything**: the flow writes the inspection switch into the same `AppSettings` blob this
screen holds a copy of, so keeping the copy would show a setting that is no longer the saved one.

**Added in M10 — *Show the introduction again*.** The screen grew one section, and it is not a
convenience: it is the half that makes skipping the first-run intro safe. Marking the intro as seen on
one tap is only defensible because it can be asked for again from here; without this row, skipping
would lose it forever. Asking for it does not clear the stored flag — an app killed mid-reread should
not bring the intro back on the next launch — and the screen is also where the app admits it could not
record that the intro was seen, which is deliberate: saying so mid-onboarding would be an
incomprehensible failure about something the user does not yet know exists. See
[`onboarding-and-consent.md`](onboarding-and-consent.md).

**Added in M8 (2026-08-13) — the *Decrypted content* section.** The screen grew the controls of
[ADR 0007](../decisions/0007-decrypted-content-retention.md): a switch that writes the contents of
inspected connections to the device, an expiry picker of its own (1 hour / 1 day / 1 week, one day by
default, **no "forever"**), and a deletion that takes only that. It sits **directly under *Secure
traffic*** and not among the storage caps, even though one of its controls is an expiry: what makes
the second switch comprehensible is the first one right above it, and the footer's job is to carry the
difference between *looking inside* traffic while it happens and *keeping a copy* of what was decoded.
Four things it says that are not obvious. **It can only be turned on with inspection on** — nothing is
being decoded otherwise, so it would govern nothing, and the footer says that rather than leaving a
dead switch — **and it can always be turned off**, whatever else is true, because revoking permission
to store what you say inside your own traffic cannot wait for anything to cooperate; the control
channel stops a live session recording at once. **The two things the user does not decide are said
where they choose the one they do:** there is no unlimited option and there is a fixed 512 MB ceiling
above their expiry (a test ties that figure to the constant the sweep enforces). **Deleting is both
halves or it lies:** emptying the index leaves the bytes on disk and the sweep only removes what
nothing references, so the gesture chains them — and the file being written is spared here for the
same reason it is spared everywhere, which the dialog says before the user accepts. **The storage
block counts it**, as a third row that appears only when something was decrypted and inside the total,
because leaving the most sensitive artefact out of "how much room is this app taking" made that figure
smaller than the one iOS shows; *Delete everything* names it too.

### Session diagnostics

The last row of Settings, and the only screen in the product written for someone who is **debugging**:
it says in one sentence whether looking inside secure traffic is working, and then shows the counters
that sentence was read from (inspection, names, decrypted content, recording, forwarding, and the last
errors). It is a row of its own at the end rather than a control among the switches because it decides
nothing — it answers *is what I think is happening actually happening?*.

The sentence is the screen. It separates the cases that look identical from the outside and cost the
most to tell apart on a device: nothing was ever offered for inspection, the connections offered were
not TLS at all (an app speaking its own protocol over 443), every app that was inspected pins its
certificates (which is [ADR 0003](../decisions/0003-no-third-party-pinning-bypass.md) working, not a
fault), and — the one worth acting on — **connections were named and still never taken over**, which
is what a missing CA inside the extension or a refused local listener looks like. That last one says
browsing keeps working, because the degradation is silent by design and otherwise the reader goes
hunting for a broken internet connection.

With the tunnel off the screen says so and asks nothing: the counters start at zero with every
session, so there is nothing to show and nothing to query.

**Above that sentence, when there is one, sits a second one about name resolution** — and it goes
first on purpose: inspection is an optional feature that degrades silently, and this is whether the
device can look up names at all while monitoring is on. It appears only when something is wrong: the
tunnel announced no DNS server (because the system could not be asked, because the network offered
none, or because none of them could be passed on through a tunnel), or name lookups are going out and
**nothing is coming back** — which is exactly what a page loading forever is. When that happens after
the device changed network and the tunnel could not pick up the new servers, it says so, because then
the cause is known and so is the way out: turn monitoring off and on again. When the tunnel is
announcing servers and lookups are being answered, it says nothing at all: a notice that appears when
everything is fine teaches the reader to ignore it.

The *Name resolution* table below carries the three lists — announced, what the system said when they
were announced, what it says now — and the counters of the re-announcement: how many network changes
were handled, how many of them produced new servers, and how many failed. Those two numbers are worth
reading together, because they are the live measurement of whether the tunnel can still see past
itself after it becomes the primary interface.

## TLS inspection setup
The multi-step, system-round-trip flow fully specified in
[`onboarding-and-consent.md`](onboarding-and-consent.md). Must show live per-step status and
detect partial completion (profile installed but trust not enabled).

**As implemented (M10):** the sixth screen, pushed from Settings — not a tab (it is not somewhere you
live, it is a decision you take and leave) and not a sheet (the flow leaves the app repeatedly, and
coming back into something a swipe can dismiss is worse). One stage is on screen at a time, and which
one is **derived from the system on every turn**, including on every return from the background: that
is what makes "live status" honest here. **"Live per-step status" has a floor, and this screen is where
it shows:** iOS exposes no way to know whether a certificate is installed, so partial completion cannot
be detected — steps 2 and 3 are presented together, with a note saying why the app cannot tell which is
missing, and the only thing ever asserted is the final answer. The share sheet is preceded by a screen
of our own, because handing the profile over is the one moment a file of ours can leave the device.

## Cross-cutting

- **Empty/error/loading** states designed for every screen (principle 7).
- **Dynamic Type + VoiceOver** on every screen, charts included (principle 6).
- **Dark/light** both first-class (see [`design-system.md`](design-system.md)).
- No screen ever shows developer jargon to the user.
