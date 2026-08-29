# UX — Onboarding and consent

The two hardest UX moments are (1) approving the local VPN and (2) installing and trusting the
CA for HTTPS inspection. Both involve leaving the app for a system prompt or Settings. Done
well, a non-technical user gets through them without fear; done badly, they bounce. This is the
most important UX work in the app (milestone M10).

## First run

A short, skippable 3-card intro, then land on the Dashboard in its empty state.

1. **What it does** — "See which apps and servers your device talks to. Everything stays on
   your device." One sentence, one illustration.
2. **How it works** — "TunnelVision watches traffic through a private, on-device VPN. iOS will
   show a VPN icon while it's on." Sets the expectation before the system prompt.
3. **Your privacy** — "No account. No cloud. Nothing is uploaded. You can stop anytime." Then a
   single primary button: **Start monitoring**.

No account creation, no sign-in, ever.

**As implemented (M10):** the copy, the order and both buttons of each card are a pure value,
`IntroPresentation` (`TunnelVision/Models`), driven by `IntroViewModel` and drawn by
`IntroView` — the intro covers the whole app (`fullScreenCover` on `RootView`) rather than a tab,
so nothing behind it can be tapped while it explains what this is. Four decisions the section above
does not settle:

- **Every card has a way out, including the last one.** "A single primary button" is read against
  the consent rule below (*always offer a no / later path*), which wins: cards 1–2 offer **Skip**,
  card 3 offers **Not now**. The two are named differently because they mean different things —
  skipping the rest of an explanation is not the same as deciding not to start yet.
- **The last button does what it says.** *Start monitoring* does not merely dismiss onto an empty
  Dashboard with an identically-labelled button still waiting: it lands there **and asks the
  Dashboard to start**, which routes through the already-tested `MonitoringPresentation` — so a
  device without a saved profile still gets the priming sheet first and never a cold system prompt.
  A request that arrives while monitoring is already on is dropped rather than honoured as its
  opposite (`MonitoringPresentation.startRequestAction`).
- **Where "seen" lives: `AppSettings.hasSeenIntro`**, the same durable blob the Settings screen
  writes and the extension reads. It is the only field the extension ignores, and it lives there
  anyway rather than in an app-only `UserDefaults`, which would split the product's single durable
  truth across two backing stores that can fail and be reset independently. Its factory value
  (`false`) is what makes "nothing saved yet" mean "fresh install" without a separate sentinel.
- **Skipping counts as seen, because the intro can be asked for again** from Settings → *Show the
  introduction again*. Without that way back, marking it seen on one tap would lose it forever
  (the dead end [`00-ux-principles.md`](00-ux-principles.md) forbids); without counting it as seen,
  the intro would reappear on every launch until endured in full, which is nagging.

**When the store cannot be read or written**, the intro is shown and the app carries on: a new
install cannot be told apart from an unreadable store, and of the two possible mistakes only one is
proportionate — showing three cards to someone who has seen them is an annoyance, never explaining
the VPN to someone who has not leaves them unprepared for the system prompt. Not being able to
record it does not trap the user in the intro either; the fact surfaces in Settings, next to the
button that brings the intro back, and not mid-onboarding where it would be an incomprehensible
failure about something the user does not yet know exists.

**Skippable without sight (M11).** "Short and skippable" was only half true with VoiceOver. The deck
is walked by swiping it, and the card is a single accessibility element, so the page gesture never
reaches it: all that survived of the intro's navigation was what sits in buttons — *Continue*, one
card at a time and forward only, and *Skip*, which **leaves the intro** without ever offering the
start. That left two gaps, and neither is cosmetic: **there was no way back** (no button on the screen
retreats, so a card someone wanted to re-read was only recoverable by swiping), and **there was no way
to the end** — the last card is the one that asks to start, and the only route to it was reading all
three. The fix is the same shape as the Timeline's axis: the card becomes **adjustable** (one card per
swipe, clamped at both ends — the intro announces "3 of 3", and wrapping round to the first would
contradict what it just said), plus named actions for what a finger does at a glance. All of it is
decided in `IntroAccessibility` (pure), and both routes end in the same `show(_:)`, so what a finger
applies and what VoiceOver applies cannot drift apart. Three rules worth naming:

- **Going forward is not offered as an action.** The card's primary button already *is* "the next
  one"; a second name for the same move lengthens the rotor and adds nothing to do. By the same rule,
  *Go to the last step* is offered only where the end is not already the next card — from card 2,
  *Continue* lands in exactly the same place.
- **The jump is not called *Skip*.** It is what a sighted user does when they skim past the
  explanation, but *Skip* is the name of the button that **ends** the intro: two things called the
  same, one moving inside and one leaving, is precisely the confusion this traversal exists to remove.
  It is named for its destination instead.
- **Nothing offered is inert.** Every action that appears leads somewhere, and never to the card
  already showing — an action that does nothing is worse than an absent one, because whoever activates
  it cannot see that nothing happened.

**Not yet heard.** The rules are asserted in tests (`Views/` stays out of the test bundle), but nobody
has run VoiceOver over the intro: whether the phrases read well one after another, and whether the
paged `TabView` keeps its off-screen cards out of the way, needs the Accessibility Inspector or a
device.

## Enabling the tunnel (VPN permission)

Priming → system prompt → result, never a cold prompt.

```
[ In-app priming sheet ]
  "iOS will now ask permission to add a VPN configuration.
   This VPN is local — your traffic is not sent to us or anyone else.
   It's what lets TunnelVision watch your connections on-device."
        [ Not now ]                 [ Continue ]
                                        │
                                        ▼
        iOS system VPN prompt  ──▶  Allow / Don't Allow
                                        │
             ┌──────────────────────────┴───────────────────┐
        Allowed                                          Denied
   start tunnel, dashboard goes live         explain + offer retry, no dead end
```

- If denied, don't strand the user: a friendly card explaining what monitoring needs and a
  **Try again** button (re-invokes `NETunnelProviderManager` save/enable).
- While active, surface the state in-app (a clear "Monitoring on" affordance) mirroring the
  system VPN icon, with a one-tap stop.

## Enabling HTTPS inspection (the CA flow)

Off by default. Only reached from **Settings → Look inside secure traffic**, gated behind an
explanation of the trade-off. This flow has several system round-trips; guide each one and
show live status of where the user is.

### Step 0 — Explain the trade-off
"Turning this on lets TunnelVision read your own secure (HTTPS) traffic so you can see inside
it. To do that, you'll install a certificate you create here. Apps that use certificate pinning
will stay private and can't be read — that's normal and expected."

### Step 1 — Generate the certificate
One tap creates the local CA (private key stays on device, in the Keychain). Show that it was
created; offer **Learn what this means**.

### Step 2 — Install the profile
iOS requires installing the certificate as a configuration profile. Provide the profile and
**step-by-step, screenshot-guided** instructions, deep-linking where possible:
- Present the profile → iOS shows "Profile Downloaded".
- Guide: **Settings → General → VPN & Device Management → TunnelVision certificate → Install**.

### Step 3 — Enable full trust
A separate, deliberate iOS step (Apple designed this friction on purpose; embrace it):
- Guide: **Settings → General → About → Certificate Trust Settings → enable TunnelVision**.
- Explain why iOS makes this a second, manual step (so no app can silently gain this power).

### Step 4 — Confirm
Back in the app, verify trust and show a clear **Inspection on** state, listing exactly what
becomes visible and what stays private (pinned apps).

**As implemented so far (M10):** the app can now *ask* — `CertificateStatusReader`
([`../spec/app-services.md`](../spec/app-services.md)) answers whether a CA exists (the shared
Keychain, where `LocalCA` keeps the root key) and whether the system trusts its root (`SecTrust`,
asked in the present tense, never cached). That is what feeds Settings' availability, and it is what
steps 1–4 will be built on. Two constraints it settles, both of which shape the screens still to
come:

- ~~**"Installed but not trusted" cannot be told apart from "not installed".**~~ **False, corrected on
  2026-08-15 — and believing it cost a device session.** They *can* be told apart, because they are two
  different questions and only one was being asked. Evaluating the root alone under
  `SecPolicyCreateBasicX509` says *installed*; evaluating a leaf from that CA under
  `SecPolicyCreateSSL` says *usable for TLS*. A root installed without the step-3 switch answers yes to
  the first and no to the second, which is exactly the state this bullet claimed was invisible — and it
  is also the state that, read as "trusted", let inspection be turned on and took the device off the
  internet. What survives of the bullet is the **screen**: steps 2 and 3 still show together, because a
  user who only needs the switch loses nothing by seeing both. What changes is the **notice**, which now
  names the switch instead of sending them to reinstall
  (`CertificateSetupPresentation.installedButNotFullyTrusted`).
- **Trust is re-asked every time the app comes back, not only when it is granted.** The setting is
  durable and the trust is not: since 2026-08-15 the root view calls
  `SettingsViewModel.revalidateTLSTrust()` on appear and on every return to the foreground, and
  inspection **turns itself off** if the system has stopped accepting the CA. Without it, withdrawing
  trust from iOS Settings leaves a switch that is on and a device that cannot browse, with nothing on
  screen connecting the two.
- **Doubt closes the door.** A Keychain that cannot be read is not "no certificate yet", so the flow
  must not offer to generate one on top of it: generating replaces the root key, which would silently
  invalidate the certificate an existing user already installed and trusted.

**As implemented (M10, the flow under the screen):** steps 0–4 are a pure value
(`CertificateSetupStage` + `CertificateSetupPresentation` + `CertificateSetupPolicy`, in
`TunnelVision/Models`), driven by `CertificateSetupViewModel` over `CertificateStatusReader`,
`LocalCA` and a new `CertificateProfile`/`CertificateProfileExporter`
([`../spec/app-services.md`](../spec/app-services.md)). Five decisions this section does not settle:

- **The certificate is handed over as a configuration profile (`.mobileconfig`), not as a bare
  `.cer`.** That is what makes steps 2 and 3 above describe the screens the user actually sees
  ("Profile Downloaded", *VPN & Device Management*), it lets the thing iOS asks them to trust say
  *TunnelVision* and what it is for, and it gives them the object they later remove. The profile
  declares itself removable, and its identity is **fixed**, so remaking the CA replaces the installed
  anchor instead of stacking a second one nobody would think to delete.
- **iOS marks the profile *Not Signed*, so the flow says so first.** Signing it would need a
  certificate the device already trusts, and the only one we have is the one not installed yet. A red
  warning on a certificate is exactly what teaches people to back out, so it is named before it appears
  — the same rule as the VPN priming sheet.
- **Where the user is comes from the system, not from a counter.** Every part of this flow happens
  outside the app; the stage is derived from `CertificateStatus` on every turn, so installing the
  profile with the app in the background and coming back lands them where they really are. Step 0 only
  stands in front of *creating* — a CA that exists was created by someone who read it — but each visit
  re-explains, because the explanation is the gate in front of a decision, not a formality.
- **Remaking the certificate is a separate action from creating it**, with its own confirmation naming
  what is lost: `LocalCA.generate` replaces the root key, so the certificate the user already installed
  and trusted stops signing anything. `canGenerate` is only true when it is **known** that there is no
  CA.
- **Inspection is turned off before the certificate is touched, and if it cannot be turned off the
  certificate is left exactly as it was.** The saved setting is the extension's only gate: leaving it on
  with a root that just stopped being valid would break connections that work today, which is worse
  than doing nothing at all.

**As implemented (M10, the screen):** `CertificateSetupView` (`TunnelVision/Views/Settings`) draws the
stage, its guidance and its buttons; `SetupStepList` draws one numbered instruction; and
`CertificateProfileSheet` stands between the *Install certificate* button and the system share sheet.
The screen decides nothing — every string, every button and every rule about what may be offered comes
from the pure core above. Four decisions that belong to the drawing:

- **It is pushed from Settings, not presented as a sheet.** The flow leaves the app several times (to
  Files, and to two different places in iOS Settings), and coming back into a modal that a stray swipe
  can dismiss is worse than coming back to a screen with a Back button, with the tab that owns the
  switch still in view. It is the only entry point, as this page requires: deciding to look inside
  encrypted traffic happens where the switch that governs it lives.
- **Coming back from the background asks again.** Everything this flow asks for happens outside the
  app, so returning is the exact moment the system's answer may have changed. Without it, a user who
  has just installed and trusted the certificate would come back to a screen still asking them to do
  it. The stage is re-derived, never a step counter — that rule is only true if something re-asks.
- **The share sheet gets a screen of its own first.** This is the one moment in the flow when a file of
  ours can leave the device, and the system sheet does not distinguish *Save to Files* — what the
  guidance asks for — from sending it somewhere else. So `profileHandoff` says what to do with the
  file, that "Profile Downloaded" means *ready to install*, not *installed*, and that the file should
  stay on this device: it carries the certificate, never its private key, but any device that installs
  it starts trusting certificates this one creates. Same rule as the VPN priming sheet: explain
  before, never after.
- **The steps are instructions, not a checklist.** [`design-system.md`](design-system.md) asks for a
  `StepChecklist` with per-step state, and that is precisely what cannot be built here: iOS does not
  expose which certificates are installed, so of steps 2 and 3 it is unknowable which one is done —
  only the final answer can be asked for, and the stage already says it. Ticks nobody measured would
  claim progress that was never observed.

### Turning it off / removing trust
- In-app toggle stops inspection immediately (termination stops; flows go back to `encrypted`).
- Always show how to fully remove the certificate: **Settings → General → VPN & Device
  Management → Remove profile**, and confirm in-app once it's gone.

**As implemented (M10):** removing is part of the flow and not an extra. It turns inspection off, then
deletes the root key from the Keychain (`LocalCA.removeFromKeychain`), and only **then** shows the
profile-removal steps — before that there is nothing to withdraw, and the guidance would be telling the
user to undo something still in place. It also returns the flow to its explanation: turning it back on
is the same decision being taken again. What is *not* touched is said out loud in the confirmation —
history and captures stay.

## Consent copy rules

- Explain **before** the system UI appears, never after.
- Name the trade-off honestly (pinned apps stay private; this reads *your own* traffic).
- Always offer a no / later path; never a single forced button.
- Never imply data leaves the device — because it doesn't.

## States to design for every step

`not started` · `in progress (waiting on system)` · `succeeded` · `denied/failed (with retry)`
· `partially done` (e.g. profile installed but trust not enabled — detect and guide to the
exact missing step).
