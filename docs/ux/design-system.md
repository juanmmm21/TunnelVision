# UX — Design system

A small, native-feeling design system. TunnelVision should look like it belongs on iOS: system
materials, SF Pro, Swift Charts, and semantic colors that adapt to light/dark and Dynamic Type.
Restraint over decoration — this is a trustworthy utility, not a flashy dashboard.

## Foundations

### Color (semantic roles, adaptive)
Define a small role set backed by asset-catalog colors with light/dark variants; never
hardcode hex in views.

| Role | Use |
|------|-----|
| `accent` | primary actions, active monitoring |
| `surface` / `surfaceSecondary` | cards, grouped backgrounds (system materials) |
| `textPrimary` / `textSecondary` | copy hierarchy |
| `statusPlaintext` | plaintext flow badge |
| `statusEncrypted` | encrypted, not inspected |
| `statusInspected` | decrypted with consent |
| `statusNotInspectable` | pinned / passed through |
| `warning` | back-pressure/drops, storage full |

Status is always **icon + label + color**, never color alone (accessibility principle 6).

**As implemented (M9, replaced by the visual system):** the roles exist as a pure value, `StatusRole`
(`TunnelVision/Models`), and the single place that turns one into a `Color` is
`TunnelVision/Views/Palette.swift`. It used to map them to the **system semantic colors**, which
adapted on their own but belonged to nobody: the app looked like SwiftUI's factory setting.

**As implemented (visual system, roadmap step 8).** The catalog this section asked for exists:
`TunnelVision/Resources/Assets.xcassets`, one colorset per role, each with **four** variants — light,
dark, and both under increased contrast. The names are not spelled out in views: `ColorToken`
(`Models/DesignTokens.swift`) is the only door into the palette, `Views/Theme.swift` is where a token
becomes a `Color`, and `Palette.swift` keeps mapping `StatusRole` → token. Asset symbol generation is
**off** (`ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS`) precisely so there is no second door.

Two things the palette had to learn that a table of roles does not show:

- **The brand is two tokens, not one.** `brand` is the brand *as ink* — text, icons, the global tint —
  so in dark it has to be light. `brandFill` is the brand *as a fill*, with a white label on top, so it
  has to be dark in both appearances. With a single token the Dashboard's primary button came out white
  on pale cyan in dark mode.
- **A card needs an edge.** Cards were `.regularMaterial` over the system grouped background, and in
  light those two are nearly the same value: the cards were not visible as cards. The surface is now a
  colour of its own plus a one-point `surfaceStroke`.

**What is asserted, and where** (`TunnelVisionTests/Presentation/DesignTokensTests.swift`): every token
resolves in all four appearances, every token really has a dark variant (a colorset missing one compiles
fine and only shows up at night), the four connection states keep tokens of their own, and every colour
that carries text reaches **4.5:1** over the surface — **7:1** under increased contrast, or the
high-contrast variant would be a gesture rather than a help. Note for whoever writes the next such test:
`UIColor(named:in:compatibleWith:)` ignores the traits and returns the light value, so appearance-aware
assertions have to go through `resolvedColor(with:)`.

`Palette.swift` also owns `TrafficDirectionStyle`, the colour and symbol of received/sent traffic, so
the chart, the counters and the host rows cannot drift apart.

**What the list screens added (step 8, second batch).** Once Timeline and Captures moved onto the
canvas, text stopped landing only on cards, and three more things became assertable — each of which
found a real defect the moment it was written:

- **Content colours over the *canvas*, not just the surface.** The canvas is darker than a card in
  light, so a colour can clear 4.5:1 on one and fail on the other. `TrafficInbound` did exactly that
  (4.28:1) and was darkened; so was its high-contrast variant (6.64:1 against a required 7:1).
- **The card edge against the canvas.** That is the contrast that says where a card ends — the edge
  against its own surface says nothing. `surfaceStroke` was too pale in light (1.15:1) and was darkened.
- **A dimmed graphic still has to be seen.** The scrub axis draws unselected bars in `neutral` at
  `MarkOpacity.dimmed`. A bar carries no text, so the bar to measure is WCAG 1.4.11's **3:1** against its
  track — and at the half tone it used to use, light mode gave **1.98:1**. The opacity is a token now,
  measured, with a test that stops it from being lowered again.

**What the Settings screens added (step 8, third batch).** Settings, the CA flow and *Session
diagnostics* are the first screens whose content is mostly **controls and readings** rather than cards,
and that surfaced one more measurable thing:

- **A tinted fill that carries its own ink can only sit on a card.** The numbered steps of the CA flow
  draw each number in `brand` on a circle filled with `brand` at low opacity, and that mixture moves the
  background *towards* the ink — so the contrast to measure is the ink against the blend, not against the
  surface. On a card it clears 4.5:1 (7:1 under increased contrast) up to `FillOpacity.tinted`; over the
  **canvas** it never does, at any opacity where the tint is still visible at all. Hence the step list
  lives inside a card, and a test asserts both halves — the one that must hold, and the one that is the
  *reason* for the card.
- **A grouped `Form` wears the system the same way a grouped `List` does**, so Settings gets the same
  treatment Captures got: canvas behind, `surface` on every row, section headings through
  `SectionHeader`, and footers on a type role instead of the system's grey. Its large title survives
  because the canvas goes on the `Form`, not on its container — the same trap as below.

**What the Flow Inspector added (step 8, fourth batch).** The Flow Inspector, the packet screen and the
conversation are the first screens whose content is **raw material** — a hex dump, a decoded body — rather
than readings or controls, and that is what finally puts text on the third background of the system:

- **Content colours over the *sunken* surface.** A dump lives in a `.sunkenSurface()` well inside its card,
  so its offsets and its bytes are read on `surfaceSunken`, which in light sits *between* the canvas and
  the card. Five tokens cleared 4.5:1 over a white card and failed 7:1 there under increased contrast
  (6.72:1 to 6.90:1); they were darkened. That is the same defect the canvas assertion found, one surface
  further in — and the reason the rule is now *every* background a token can land on gets its own test.
- **A badge is ink on its own tint, and the tint that works for the brand does not work for a status.**
  `FillOpacity.tinted` is measured against `brand`, the content colour with the most headroom;
  `TLSStatusBadge` had a 12 % tint written by hand in the view, and at that value the amber of *not
  encrypted* left its own label at **4.25:1**. `FillOpacity.badge` (9 %) is the highest tint at which all
  nine content tokens keep their label legible in all four appearances, and a second test asserts *why*
  the two opacities cannot be merged into one.
- **The ring around a badge is deliberately not measured.** With a tint that low it is the only thing that
  makes a badge read as a badge, but it is not what identifies the state — icon, word and colour are — so
  holding it to WCAG 1.4.11's 3:1 would need a nearly opaque outline (0.71 in light) and turn the Timeline
  into a row of underlined pills. `StrokeOpacity.tintedEdge` is chosen, and says so.
- **Four monospaced fonts written by hand became two roles.** `literal` (footnote) is a datum read
  character by character — a certificate fingerprint, an exported file name, a decoded body — and `dumpLine`
  (caption) is a line of hex, the one role whose size is set by **width** rather than by reading: sixteen
  byte pairs plus their ASCII. And `rowFigure` completes the figures — title2, title3, subheadline, caption
  — so the packet list's offsets stop being the only numbers in the app that are not set as numbers.
- **Two shared components came out of it**, both because the same thing existed twice: `FactGrid` (the
  label/value grid of the two detail screens, including the rule that drops to one column at
  accessibility sizes — it had an icon per cell until the second pass, below) and `.cardRow()` (the background, the hidden separator and the summed insets that
  turn a list row into a card — the Timeline had them written inline).
- **A defect in an already-dressed screen, found by looking:** the Timeline's loading and empty bodies are
  `ScrollView`s, not `List`s, so `.listCanvas()` never reached them and they sat on the factory white. They
  carry the canvas now — and the large title survives it, which is the answer to the obvious worry about
  the trap below: the background is on the scroll view itself, not on a container around it.

**What the intro added (step 8, fifth batch).** The intro is the **first screen anybody sees**, and it
was the last one still wearing the factory default. It is also the only screen in the app whose content
is neither a list, a form nor a file — three short cards you swipe — so it is where two rules that had
only ever applied to lists had to be restated:

- **A deck of cards is a deck of *cards*.** The intro's pages had been called cards in the code since
  M10 and had never been drawn as any: symbol, headline and prose loose on the system's grouped
  background, top-aligned, with the bottom half of the screen empty. Each page is a `.cardSurface()`
  card now, and its symbol sits on a `brand` tint at `FillOpacity.tinted` — the same measured tint as
  the CA flow's step badge, which is also why the card is what makes it legal: over the canvas that
  tint clears nothing.
- **A card that fits is centred; one that does not, scrolls.** `ViewThatFits` decides that per page, and
  it is the right tool rather than a measured height because the two failure modes are opposite: pinned
  to the top, the card left half a screen of empty canvas under it; centred by force, it would clip the
  moment the copy grows — with the text size, or with a translation. And it keeps `GeometryReader` out
  of the `TabView`, which is where the `NaN` frame that once hid the intro from VoiceOver came from.
**What the intro's second pass added (2026-08-20).** The card wore the visual system correctly and
was still the least readable screen in the app, which is exactly the gap the second pass exists to
close — correct is not the same as good-looking.

- **Centring is for what is read at a glance, not for what is read line by line.** All three cards
  centred their prose, and they carry four and five lines of it (six at AX5): with a ragged entry
  edge the eye has to hunt for the start of every line. The headline went with it, because a centred
  headline over leading-aligned prose is the worst of both. And centring cost something that can be
  measured, not just judged: **a centred block shrinks to its longest line**, so the three cards of
  the deck held their content in **299, 306 and 280 points of width starting at three different
  columns** — swiping the deck moved the text sideways under the finger.
- **A card in a deck is judged against the card before it.** The same rule as the Timeline's rows, and
  it reaches the vertical axis too: the three cards measured 229, 251 and 229 points of content, so,
  centred in their page, the symbol and the headline **jumped eleven points** with every swipe. The
  floor that fixes it is a token (`DeckCard.minimumContentHeight`) and it is deliberately **only as
  tall as the deck's longest copy**: raising it until the card filled half the screen was tried and
  was worse than the problem — the floating stamp became a card with a white well at its foot, which
  is emptiness with a frame around it rather than air. Filling a screen is not a height floor's job.
- **The ornament rule applies to size and not only to curve.** The step above put the symbol on the
  flattest scaling curve; it left it at 44 points inside an 88-point disc, which is **38 % of the
  card's content height** — more than the headline and nearly as much as the whole paragraph. A deck
  that exists to be read opened with an ornament. Thirty points leaves it at just over a quarter.
- **And the disc is geometry, not a doubling.** The glyph side and the disc diameter were two loose
  `@ScaledMetric` constants tied together only by a comment, so changing one silently broke the other.
  `SymbolDisc` (pure) decides it now, and the rule is that the disc must cover the **diagonal** of the
  glyph's box — `side · √2`, which is where a padlock's shackle or a globe's rim get clipped — plus
  its breathing room. Doubling was never the rule; it was just above it.
- **The way out was the hardest thing on the screen to hit.** *Skip* / *Not now* measured **31 × 19
  points**, and it is not a secondary button: the spec's consent rule says there is never a single
  button, so it is the one that makes the primary legal. Fifth time this trap appeared — the frame
  belongs on the **label**, because in a button with no fill of its own what receives the tap is the
  text.

- **The pinned-band rule again, on a screen with no list.** The two buttons were a fixed band, and at
  AX5 *Start monitoring* is a two-line button: the band took over a third of the viewport and cut the
  copy mid-word under the page dots. Above the accessibility threshold the buttons ride at the end of
  the page's scroll, exactly as the CA flow's do. The **page dots stay pinned at every size**, and can:
  they are the one thing on the screen that never grows.
- **An ornament rides the flattest curve.** The symbol scales with the text — fixed, it would be a
  speck beside an AX5 headline — but on the `.largeTitle` curve rather than the `title2` one of the
  headline it accompanies, because it is drawn inside a disc and therefore costs twice its size. On the
  headline's curve the ornament took a third of the screen before the first word.
- **A dimmed mark over the *canvas*.** The inactive page dots are `neutral` at `MarkOpacity.dimmed`, so
  the axis's rule reaches a third background: a mark carrying no text clears WCAG 1.4.11's 3:1 against
  what it sits on. It passes as it stands — this one guards rather than fixes — and it is what stops the
  opacity from being lowered again for the sake of dark mode.
- **The same prominent-button defect, in the last three places that still had it.** The intro's primary
  button, `ConsentSheet` and `FlowExportSheet` were all plain `.borderedProminent`, so their fill was
  the *ink* token: white label on pale cyan in dark. All three go through `.brandProminentButton()`
  now — and the intro's was also a narrow pill in the middle of the screen, because the width was on the
  button rather than on its label, which is the one place a `.frame(maxWidth:)` does not reach the
  padding. The two sheets became scrolling bodies on the canvas at the same time, like
  `CertificateProfileSheet`: at AX5 their action had been pushed off a medium detent with no way to
  reach it.

**Four layout facts that a redesign runs into and that cost builds to find:**

- **A background on the view that *contains* a `List` — or any background reaching into the top safe
  area — leaves the navigation bar with no large title**, and no inline title in its place: the screen
  loses its name. The canvas goes on the `List` itself (`.listCanvas()`) and on the pinned band beside
  it, never on their container.
- **`.navigationBarDrawer(displayMode: .always)` costs the large title too.** A search field that is
  always visible in the drawer left the Timeline with *no* title at all — not large, not inline — and a
  hundred-odd points of empty space above the search field where the title should have been. Dropping
  the placement (the default already puts the field in the drawer) brings the title back. What survives
  is a first-frame quirk unrelated to it: entering the tab, the large title is not drawn until the list
  is touched once. That one is iOS's, was there before, and is not worth chasing.
- **A pinned control cannot grow with the text.** At accessibility sizes the scrub bar's caption needs
  five or six lines — and it may not be truncated — which fixed at the top eats the whole viewport and
  leaves the connections unreachable, because a pinned band does not scroll. Above the accessibility
  threshold the axis stops being pinned and becomes the first row of the list.
- **Whatever scrolls under a navigation bar needs the bar to be opaque.** The consequence of the rule
  above: as the list's first row, the scrub axis slides under the bar, and iOS 26's bar is glass — so
  the axis's caption read *through* the title and the search field. Re-pinning the axis is not the way
  out (see above); `.toolbarBackground(.visible, for: .navigationBar)` with the canvas colour is. The
  colour is what is already underneath, so at the top of the list there is no seam to see.

### Typography
System font (SF Pro) via text styles (`.largeTitle`…`.caption`) so Dynamic Type just works.
Numbers in charts/counters use monospaced digits (`.monospacedDigit()`) to avoid jitter as
values update.

**As implemented (step 8):** the scale is a set of **roles** on `Font` (`Views/Theme.swift`) —
`screenHeadline`, `cardTitle`, `prose`, `cardBody`, `supporting`, `sectionHeader`, `badge`, the four
figures (`metricValue`, `readingValue`, `rowValue`, `rowFigure`) and the two monospaced ones (`literal`,
`dumpLine`) — and every one of them is built from a system text style, so Dynamic Type keeps working without any view
remembering to ask for it. The two that carry numbers (`metricValue`, `readingValue`) bring the rounded
design and the monospaced digits with them, which is what stops a live figure from changing width
several times a second. Hand-drawn section headings go through `SectionHeader`, which sets them in caps
with tracking — and hands VoiceOver the original text, because some engines spell out sustained caps.

### Spacing & layout
An 8pt soft grid; grouped `List`/`Form` for settings; cards use system materials
(`.regularMaterial`). Respect safe areas and large-title collapse.

**As implemented (step 8):** the grid is `Spacing` and the radii are `CornerRadius`
(`Models/DesignTokens.swift`), both pure and both asserted to grow and to sit on the grid. Cards are no
longer system materials: `.cardSurface()` paints `surface` with a `surfaceStroke` edge at
`CornerRadius.large`, `.screenCanvas()` puts `canvas` behind a screen, and `.sunkenSurface()` is for
what sits *inside* a card (dumps, conversation bodies). The radius is what says whether something is a
card, a tile inside one or a small control — three sizes, not one per view. Everything must lay out at
the largest accessibility text sizes without truncation or overlap. Rows that place several
things side by side (a reading next to its actions, tiles in a row, metrics in a line) switch
to a stacked layout at accessibility sizes via `AnyLayout` — an `HStack` does not wrap, so at
those sizes side-by-side means truncation. Fixed point sizes (icon columns, numbered badges)
scale with `@ScaledMetric`; the hex dump keeps its columns and scrolls horizontally instead,
because wrapping a 16-byte line destroys the very alignment that makes it readable.

**Anything a finger lands on owes 44 pt** (`TouchTarget.minimum`, written once because more than one
screen owes it). Two traps found while measuring it (2026-08-18), both about *where* a size is
applied: on a system button style, a `.frame(maxWidth:)` or `.frame(minHeight:)` put on the **button**
moves the space around it and not the fill that receives the tap — the width and the minimum go on the
**label** — and what a control really offers a finger is not what a screenshot suggests but what
`idb ui describe-all` reports as its frame. The monitoring strip's button measured **34 pt** that way
while looking perfectly tappable.

**And a tiled control owes it too — which is what decides the Timeline's axis** (2026-08-18). The
scrub axis exists to *pick* a stretch of the past with a finger, so an interval is a touch target like
any button. At 48 bars it offered **14 pt** each: aimable only with care, and drawn as a smear rather
than a shape. Intervals tile the axis, so they cannot be padded apart — the only way to make one 44 pt
wide is to offer fewer, and the number that fits is a property of the **screen's width**. So it is
measured where the screen is (`TimelineView`'s zero-height probe), decided in a pure function
(`ScrubCapacity`) and applied by the one place that already held the bar cap
(`HistoryReader.setAxisCapacity`; `HistoryPolicy.axisBars` stays as its ceiling). What is lost in
resolution is bought back by the gesture the axis already had: **tap a bar to zoom into it**. Two
things fell out of that and are part of the same decision:

- **The axis dropped its in-chart labels at every text size.** Reserving room inside the plot for half
  a label at each end cost **84 pt** — almost two intervals — to date the axis less precisely than the
  caption row underneath already does (both ends, wrapping instead of truncating). That row used to
  appear only above the accessibility threshold; now it always does, and the truncated-label trap is
  gone with it.
- **The ladder of round bucket widths grew its missing rungs** (30 s, 30 min, 2 h, 4 h, 12 h). Asking
  for five bars from a ladder that jumps from one hour to six answers a six-hour history with **two**,
  which is not an axis any more.

**`ViewThatFits` is right for one control and wrong for two hundred rows** (2026-08-19). The Timeline's
connection row was first laid out with it — service and figures share a line while they fit, otherwise
the figures drop below — and the result was a list whose rows had **different shapes for the same
content**: `1 min 17 s` is six characters longer than `48 s`, so one row wrapped and its neighbour did
not. A control is read on its own and adapting is what it should do; rows are read **against each
other**, and there the shape of a row cannot depend on how many characters its duration happened to
need. So the row's lines are fixed and the width question is answered by what goes *on* them. (The
Dashboard's strip decides the opposite way, and both are right: the trap is treating them as the same
question.)

**A repeated badge is decoration; the exception is the datum** (2026-08-19). Every Timeline row carried
the encryption badge — icon, label, tinted capsule, edge — so on an ordinary history the most contrasted
element of every row said *Encrypted*, which is precisely what the list already assumes. In a list the
status becomes a **mark** in a leading rail (the symbol, in its role colour, one column the eye runs
down) and only a **departure** from that assumption spells its name: `TLSStatusPresentation.emphasis`
decides, it is a pure value with no default like `MonitoringProminence`, and a test asserts the reason
it is allowed to hold — a state may go unspoken only while its symbol tells it apart from the other
three. The capsule stays in the Flow Inspector: the badge belongs to the file on one connection, not to
the index of all of them. At accessibility sizes there is no rail (a symbol on the headline's curve at
AX5 takes the width the host needs), so all four are spelled.

**A rail is for telling states apart, not for saying what kind of thing a row is** (2026-08-20). The
Timeline's leading rail earns its column because four states share it and the mark is what separates
them. The capture list has one assumption — a finished file — and one exception — the one the
extension is writing — so a symbol on every row would say *this is a capture file* in a list of
capture files, which is the decoration the Timeline row had just been rid of. **So the capture row has
no rail**: the exception keeps its badge, because that is what a departure gets, and the assumption
says nothing at all. The rule that travels is the previous one; the rail is only one of its answers.

**A figure that is read by comparing owes a column** (2026-08-20). The capture row said `2.2 MB · 20
Aug at 05:49` in one grey supporting line, which set the screen's only figure as prose. Size and time
are read for different reasons — the time *locates* a file and is read on its own, the size is read
*against the other rows* — so the size moved to the end of the headline in `rowFigure` (fixed-width
digits, right edge on one vertical down the list) and the time was left alone underneath. Because the
open file offers no action, the trailing slot keeps its `TouchTarget.minimum` width **whether or not
anything is in it**; otherwise that one row's figure would step 44 pt out of the column the change
exists to build. Same reasoning as the Timeline's three equal columns, and the third application of
`rowFigure` after the packet list and the connection row.

**A grid of a fixed size can be paired; one whose size the data decides cannot** (2026-08-20). The
packet screen's summary was seven facts in two columns and ended in an orphan — but pairing them was
the wrong move twice over. Three of the seven were about the **record on disk** and not about the
packet (*Bytes saved*, *Capture file*, *Position in file*), so they now read under the **Raw bytes**
heading, above the bytes whose provenance they are. And *Bytes saved* did not move, it **went**: it
repeats *Size* in every packet that fits whole, and in the one where it does not, the footer under the
dump already says it in words with both figures — a hole in a grid closes by removing a datum, and this
one was redundant on both branches. What is left is three facts that are **always** three, because the
fourth (*Flags*) only exists on TCP, and it went to the headline that already **reads** it: *Connection
opened* is what `SYN` means, which is where `PacketRow` puts the acronyms in the list you arrive from.
Three short facts take `.line`, so the summary has the same shape on every packet. **The headers grid
keeps `.pairs` and may end with a single cell**, deliberately: how many fields there are is the
protocol's business (four without a transport, five on UDP, six or seven on TCP) and step 10 will add
more, so evenness there could only be bought by inventing a fact or hiding one. What it did owe was the
**order**: with the IP version first and the protocol fourth, *From* and *To* fell in different rows
**and** different columns — the two ends of one journey read on a diagonal, the same defect the Flow
Inspector's header had just lost. They are neighbours now, behind the pair that says which two layers
this is (*IP version*, *Protocol*), and a test asserts it on IPv4, IPv6 and UDP.

**A standing rule is not a row; what is true right now is** (2026-08-20). Settings is the screen with
the most rows and the only one read end to end, and measured with `idb ui describe-all` its
explanatory prose came to **775 pt** against **663 pt** of every control on it — the explanation
outweighed everything it explained. Three of the seven sections put the note explaining a picker
*inside* the card, as a row of its own, and in *Decrypted content* that 92 pt paragraph stood between
the picker and the destructive button, so the card stopped grouping anything. A note and a footer were
also the same size, the same weight and the same colour: the only thing telling them apart was which
side of the card's edge they fell on. **All of a section's standing prose now sits under it**, in the
order of the rows it speaks about, and the cards are groups of controls again. The one text that stays
a row is the one that is not a rule — *the intro could not be remembered* is a fault happening now,
appears only when it happens, and belongs beside the button whose behaviour it contradicts. Moving the
prose out also **shortens** it, because outside a card it has the full width: 775 pt of prose became
**627 pt** and the screen is **81 pt shorter** overall.

**One fact, one place** (2026-08-20). *Why a database does not hand back the space of deleted rows* was
written under **Storage**, beside the history figure that shows it, **and again** under **Limits**,
half a screen away, as the reason the size cap covers only capture files. The mechanism stays where the
figure is; the note under the cap keeps the consequence and names that section (interpolated from its
own key, so it cannot call it something the screen does not). Same rule as the badge that spoke its
sentence twice in the Flow Inspector: a screen that says one thing twice is longer *and* less clear.

**A table's figures are its data; what makes them up is context** (2026-08-20). Settings' storage rows
were the only *data* on that screen and were written as prose — `3 files · 6.6 MB` in a single string,
so the one figure the section is read for (which of these is eating the disk, and what they come to)
shared its role and its colour with a count that compares with nothing. The two travel separately now
(`StorageFigure`), the size taking `rowValue` at the end of the line and the count `metricLabel` in
`neutral` beside it, and the `·` left the catalog with them — what separates the two is the type role
and the colour, exactly as in `CaptureFileRow` and `FlowRow`. **The total is the only row drawn with
emphasis** (`isTotal`, a caller's decision with no default, like `MonitoringProminence` and
`FactGridLayout`): it is the figure that answers *how much room is this app taking* and the other three
are its breakdown, so it takes the section's only foreground-ink figure and the card title's weight.
Drawn as four identical rows, the sum had nowhere for the eye to land. It also **never carries a
count** — it adds files, connections and conversation chunks, which have no common unit — and at
accessibility sizes the three parts stack, decided by the text-size threshold and not by fit, because
`255 connections` wrapped to three lines beside a size that stayed on the first.

**The frame must not outshout what it frames** (2026-08-20). The decrypted conversation is the one
screen whose whole point is the material — a header block, a JSON body, a hex dump — and its turn cards
painted the direction *word* in the direction colour at card-title weight, so the most contrasted thing
on the screen was **Sent**: repeated, alternating and entirely predictable, above the content it merely
labels. The colour goes back to the **mark**, as in `FlowRow` and `PacketRow`, and the word takes
ordinary ink like a host or a file name. Three more defects came out of the same measurement, and all
three had been fixed elsewhere in the same week:

- **The share button offered 19 × 22 pt** — the only action on the screen, on every card. The frame goes
  on the **label** (fourth place that trap has been found) and the slot reserves `TouchTarget.minimum`
  **whether or not it is filled**, so a turn with nothing to share does not step the figure column.
- **The size had no column.** It sat glued to the offset in the same role and the same grey, so three
  consecutive turns put their figure on three different verticals. The offset *locates* a turn and stays
  with whoever spoke; the size is read **against the other turns** and now ends the line in `rowFigure`.
  Same fix, and same reason, as `CaptureFileRow`'s.
- **A comment claimed the header was heard as one phrase, and `children: .contain` is precisely what
  does not do that**: VoiceOver stopped three times, while the sentence the pure core composes
  (`ConversationTurnPresentation.accessibilityLabel`) had a test and **no caller**. The reading group is
  `.ignore` plus that label now, with the action outside it so it stays reachable — `CaptureFileRow`'s
  shape exactly.

**Framing bytes are not material** (2026-08-20). Every text protocol closes its header with a blank
line, so *every* HTTP turn ended in line breaks that drew as a lane of air at the foot of its well: four
lines occupying six, measured, and a different amount in each turn — so two cards of the same shape did
not measure the same. The drawing trims the **trailing** whitespace only (the blank line *inside* a
response is the structure that separates headers from body) and never empties a turn. The subtlety is
in the sentence about what was left out: it now measures against the bytes **read**, not the bytes
drawn, because counting the trim as withheld would make a whole request announce itself as partial —
the same *not kept* / *not drawn* confusion the packet screen already separates into two keys.

**In a table of forty-eight rows, what sits in the value slot is not all the same kind of thing**
(2026-08-21). *Session diagnostics* is the last screen of the second pass and the only one a Simulator
session could not look at: its counters arrive over the control channel, so a seeded app still showed
its empty card. Seeded ones (`Shared/Fixtures/TunnelStatsFixture.swift`, Debug-only like the rest)
made it visible, and the first look found forty-eight rows drawn identically — *Packets recorded*,
*Database failures* and the sentence the system answered with all carrying the same weight, so the
question the screen exists for (*what is wrong?*) had to be answered by reading them one at a time.
`DiagnosticsValueRole` decides it now: pure, **no default**, three contents rather than three greys.
A **reading** is what almost all of them are; a **fault** is work lost to a failure whose counter is
not zero, and it takes the warning token with a symbol beside it — never colour alone — plus a spoken
sentence composed in the pure core, because a symbol cannot be heard; and the **system's own text** is
not our copy at all, so it stacks under its label in the `literal` role on a `.sunkenSurface()` well,
exactly as the CA flow's keychain diagnostic and the packet dump. That last one also fixes a layout
defect: a whole `NSError` in the value column stacked the row anyway *and* read as the app's prose.
Two halves of the rule matter equally, and the second is where the restraint lives:

- **The `if` that decides lives once.** `DiagnosticsRow.fault` takes the number, not its text, because
  the difference between a failure happening and one that never happened is the zero — so the check is
  written in the factory instead of at forty-eight call sites.
- **What is *not* marked**, even when it is not zero: flows that refused the certificate (ADR 0003 —
  the product doing what it promises), limits doing their job (content over the per-connection
  allowance, captures reclaimed, content expired), and other people's network failures (connections
  refused, connections that dropped). Painting amber on what a healthy session produces anyway turns
  the mark into the decoration the Timeline had just taken off its repeated badge.

**A comparison you leave to the eye is a fact repeated** (2026-08-21). The same screen's name-resolution
section took **409 of the 640 usable points** — two thirds of the viewport — and three of its six rows
were the same list of addresses, one under the other. The written reason ("the comparison is the datum")
left the comparison undone, and in the normal case the three are *guaranteed* to match rather than
happening to: while monitoring, the tunnel is the primary interface, so what the system reports back is
what the tunnel just announced (measured on hardware, `ResolverStatus.reportedNow`). A row that by
construction repeats the one above it is not a comparison. `ResolverListing` (pure, no default) makes
it: agreeing, **one** row plus a footer saying why one is enough — and saying honestly what that
agreement is worth, because selling it as a second opinion would invent a check nobody ran; diverging,
all three with their names, which is the fault the section exists to show. A list that *could not be
read* agrees with nothing. It also removed a shape defect only the full screen shows: those three rows
**stacked** (the value does not fit the column) while the other three in the same section were
two-column, so one table had two row shapes; now all four have one. Same rule as Settings' prose: the
standing note goes **under** the section, never inside the card.

### Iconography
SF Symbols throughout (`shield.lefthalf.filled`, `lock`, `lock.open`, `bolt.horizontal`,
`chart.line.uptrend.xyaxis`, `clock.arrow.circlepath`). Consistent weights.

### App icon
**As implemented (roadmap step 9, 2026-08-18).** The icon is the app's own shape receding into
light: five nested **superellipses** — the family the iOS icon mask itself belongs to — each one
lighter than the one containing it, ending in an almost-white aperture with a soft glow behind it.
A tunnel with its end visible, said with the palette and without a letter in it. It is deliberately
not a shield, a lock or an eye: those are the three marks every network utility already wears, and
none of them says *this* product, which is the one that lets you look **inside** what leaves your
phone.

Four decisions carry it:

- **Superellipses and not rounded rectangles**, because the corner then rounds *in proportion* to
  the size, so every inner layer is the same shape seen further away. With a fixed corner radius the
  small ones come out nearly square and the perspective dies. The exponent is 5, which is the corner
  of the system mask; the nesting is therefore self-referential on purpose — what recedes is the icon.
- **The ramp is the meaning.** Flatten the lightness steps and what is left is a square with
  decoration that says nothing at 40 pt. That is a one-line change in the renderer, which is why a
  test measures it (below).
- **Three variants, one geometry**: the default one on the brand blue darkened until the cyan
  ignites, a **dark** one sunk further (an icon drawn for a dark screen, not the usual one with less
  light), and a **tinted** one in **greys** — the system does not tint on top of colour, it maps this
  image's luminosity onto the tint the user picked, so what decides the result there is the same step
  of light measured in grey.
- **It is drawn from code, not stored as a picture**: `Tools/AppIcon/RenderAppIcon.swift` writes the
  three 1024×1024 PNGs of the set, reproducibly byte for byte. An opaque binary cannot be reviewed,
  retouched or re-derived when the brand moves; here the measurements and the colours are written
  down and the file is the source. `ASSETCATALOG_COMPILER_APPICON_NAME` — empty throughout
  development so `actool` would not fail the build — names the set now.

The background gradient and the aperture's glow are the one place this document's *no heavy
gradients* rule does not apply: it governs the app's chrome, where decoration competes with data. An
icon has no data to compete with, and both are shallow enough to read as a single surface.

**What is asserted** (`TunnelVisionTests/Presentation/AppIconTests.swift`, 4 tests): that the bundle
actually ships a primary icon (with the setting empty the build still passes and the app installs
with the system's grey square), that it is **fully opaque** (App Store rejects an icon with an alpha
channel, and that verdict arrives at upload time), that it **gets brighter towards its centre** band
by band, and that every band sits within 10° of the `brand` token's hue — which is what keeps the
icon's blue and the palette's blue from becoming two definitions. **What could not be asserted**:
the dark and tinted variants. `actool` leaves the default PNG loose at the bundle root and that is
what `UIImage(named:)` returns, traits or no traits — checked, pixel for pixel identical — so those
two were verified by looking (the dark one on the Simulator's home screen, where iOS does pick it up).

### Motion
Subtle and purposeful: chart updates ease, list inserts animate lightly. Honor **Reduce
Motion** — fall back to cross-fades/no motion.

## Components (reusable SwiftUI views)

- `MonitoringToggle` — the Start/Stop control with state (off/starting/live/error). **It has two
  weights since the second design pass (2026-08-18)** and the presentation decides which
  (`MonitoringProminence`): a **card** while there is something to offer — starting, or getting out of
  a failure — and a one-line **status strip** while the tunnel is working or moving. That is the fix
  for "the control eats half the Dashboard": what changed is the weight, not the clarity. Both forms
  carry the same headline, the same explanation and the same action, and the property has **no default
  value** so a new state has to choose. The strip's headline and button share a line only while they
  fit (`ViewThatFits`, not the accessibility threshold — what overflows is *width*, and two growing
  texts do that before AX1); when they do not, the button drops below and takes the width. Live gets a
  **closed** shield (`checkmark.shield.fill`) rather than the off state's half-filled one: in the strip
  the symbol stands alone, so it is what tells on from off without colour.
- `ThroughputChart` — Swift Charts line/area of in/out over a rolling window; VoiceOver summary.
- `FlowRow` — one connection: host and time, what it was, what it moved. **A rail and three lines
  since the second design pass (2026-08-19)**: the encryption mark in a leading column, and the
  three figures spread as equal columns so they line up down the list (the only part of the row
  drawn as a table, because it is the only part read by comparing). The badge, the clock next to
  the duration and 16 pt of row height went with it — 102 pt per row became **86**, one more
  connection per screen, measured with `idb ui describe-all` rather than eyeballed.
- `TLSStatusBadge` — icon+label+color for the four `TLSInspectionStatus` cases. It is the **Flow
  Inspector's** now: a list shows the mark alone unless the state departs from what the list
  assumes (see *Spacing & layout*). It keeps speaking its **whole** description (label *plus* the
  sentence explaining it) because a caller may show it with that sentence nowhere on screen — and the
  Flow Inspector, which prints the sentence right under it, therefore speaks the block itself as one
  element. Left to the badge, VoiceOver read that sentence **twice in a row**, which is the kind of
  defect only `idb ui describe-all` finds.
- `FactGrid` — the label/value grid of the two file screens. **How many columns it takes is now the
  caller's decision and has no default** (`FactGridLayout`, 2026-08-20): `.pairs` is the two-column
  table read row-major, `.line` is a single row with a column per fact. Both collapse to one column at
  accessibility sizes, which is the rule that was always there. **It has no icons since the second design
  pass (2026-08-20)**, and the reason is the same one that took the clock off `FlowRow`'s duration: a
  symbol next to a word that already says it is decoration — a ruler beside *Size*, a `#` beside
  *Sequence*, thirteen of them across the two screens. Here it also cost the only alignment a grid has:
  the icon took the label's leading while the value started at the cell's edge, so **no value sat under
  its own label** and the two columns lined up on nothing but their left borders. The symbol stays where
  it **replaces** a word (`PacketRow`'s arrows, `FlowRow`'s mark rail), never where it repeats one.
- `StatTile` — labeled metric (active flows, data used) with monospaced digits. The three of them sit
  under a `SectionHeader` since the second pass: *Received* and *Sent* appear twice on the Dashboard
  —as a per-second rate in the chart and as a session total here— and without a heading naming the
  period, the screen shows the same two words twice.
- `DropIndicator` — subtle, honest back-pressure/drops signal (warning role).
- `StepChecklist` — the CA-flow step tracker (per-step: pending/in-progress/done/failed).
  **Built as `SetupStepList` instead (M10), and without the per-step state**: iOS exposes no way to
  tell whether a certificate is installed, so of the flow's two Settings round-trips it is unknowable
  which one is done — only the final answer (does the system trust the root?) can be asked for, and
  that already governs the stage. A checklist would have to invent its ticks, which is worse than a
  numbered list without them. What survives of the original intent is the numbering: the user follows
  it with the device in hand, leaving the app between one step and the next.
- `EmptyStateView` / `ErrorStateView` — teaching empty states, actionable errors.
- `ConsentSheet` — the priming/explanation sheet used before every system prompt.

## Charts (Swift Charts) guidance

- Keep to two series max on the live chart (in/out); label units clearly (KB/s, MB).
- Provide an `.accessibilityLabel`/`AXChartDescriptor` so VoiceOver reads real values.
- Cap redraw frequency (coalesce with the ring-buffer drain cadence) so the chart never becomes
  a CPU/battery drain under heavy traffic.

**A chart that is also a control needs more than a label (M11).** The Timeline's scrub bar is read
*and* operated: tapping an interval filters and zooms, sweeping several bounds the list. A summary
alone would describe it without making it usable, so the axis is an **adjustable** element with a
focused interval, a default action that applies what has been chosen, and named actions replacing the
drag. All of it is decided in `ScrubAccessibility` (pure), not in the view — the same split as
everything else — so what VoiceOver applies and what a finger applies cannot drift apart. The
`ThroughputChart` stays summary-only on purpose: it is a readout of the last minute, with nothing to
pick.

**The same applies to anything navigated by swiping the content itself (M11).** A paged `TabView` is
one accessibility element per page and the page gesture does not reach it, so a deck that is only
walked by swiping is, without sight, a deck with no navigation but its buttons. The first-run intro
gets the same treatment as the axis — adjustable to move card to card, named actions for what a
glance does — decided in `IntroAccessibility` (pure). Two rules generalise: an action is not worth
offering when a visible button already makes the same move, and no offered action may be inert or
borrow the name of a control that does something else (see
[`onboarding-and-consent.md`](onboarding-and-consent.md)).

## Dark & light

Both are first-class. Use semantic/system colors and materials so the app adapts automatically;
verify contrast in both. Test every screen in both appearances and at max Dynamic Type as part
of the M11 polish pass.

## What to avoid

- No custom fonts, heavy gradients, or skeuomorphic chrome — it undercuts the "trustworthy
  utility" tone.
- No jargon in labels (see [`00-ux-principles.md`](00-ux-principles.md)).
- No color-only status, no motion that ignores Reduce Motion, no layout that breaks at large
  text sizes.
