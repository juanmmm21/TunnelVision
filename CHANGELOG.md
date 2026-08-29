# Changelog

All notable changes to TunnelVision, newest first.

TunnelVision is not distributed through the App Store — see
[`docs/APP-STORE.md`](docs/APP-STORE.md) — so releases here are source releases: build the tag
you want. Version numbers follow the app's `MARKETING_VERSION`.

## 1.0.0 — August 2026

The first complete version. Submitted to App Review on 28 August 2026 and rejected under
Guideline 5.4, which requires an organization developer account for any app shipping a packet
tunnel. The code was finished; the account was not the right shape. It is published here instead.

### Landed in August

- **Looking inside your own HTTPS, end to end.** Turning on inspection now really decrypts your own
  encrypted traffic and shows it: a connection you inspected has a *Decrypted content* screen that
  reads the exchange turn by turn, in the order it happened, and lets you share any single turn.
  Keeping a copy of what was decoded is a **second** switch, off by default even when inspection is
  on — inspecting traffic while it happens and storing what was inside it are two different things —
  and what it stores expires on its own, shorter schedule, with a size ceiling you cannot raise and a
  delete button that takes only it. Apps that pin their certificates are still passed through
  untouched and labelled *not inspectable*.
- **A packet on port 53 tells you what was looked up.** The packet screen now reads DNS messages: the
  name that was queried, the record type, and what came back — addresses, another name, or the
  server's answer that there is none. A datagram it cannot read says so, and says which of the two
  reasons applies, instead of going quiet.
- **A screen that tells you whether inspection is actually working.** *Settings → Session diagnostics*
  turns the tunnel's own counters into a sentence: inspection is working, or nothing was offered to
  it, or everything it met pins its certificates — which is the app doing its job, not a fault. It
  also reports which DNS servers the tunnel announced, so a network problem stops being silent.
- **Captures answer "is this going to fill my phone?"** The list now shows the room left against the
  limits you set, when the oldest capture expires, and whether a limit cannot be met at all — instead
  of leaving you to compare two figures on two different screens.
- **Changing network no longer breaks name resolution.** With monitoring on, leaving the house — Wi-Fi
  to cellular — used to leave pages loading forever. The tunnel now notices the change and re-announces
  the new network's DNS servers.
- **A designed app.** Every screen was redrawn on one visual system — colour, type, spacing, density —
  in light, dark and high-contrast, and then gone over a second time for how much room each thing takes
  and what is decoration rather than data. Touch targets that were too small to hit were measured and
  fixed. And it has an icon.
- **Fixed: the two buttons that manage your certificate.** *Create a new certificate* and *Remove
  certificate from this device* showed their confirmation and then did nothing at all. They work now,
  a destructive action that can no longer be carried out says why instead of going quiet, and creating
  a new certificate clears the instructions for retiring the old one.
- **Packets you can actually read.** The packet screen no longer shows only a hex dump: it decodes the headers and names the endpoints, the protocol, and TCP's sequence, acknowledgment, and window. When a packet cannot be decoded, it says which of the two reasons applies — bytes cut short when capturing, or bytes that simply do not parse — instead of hiding the section. The dump itself can now be copied or shared as text.
- **Storage limits hold while you are away.** Retention caps used to apply only while the Settings screen was open, so a tunnel capturing overnight could sit above its limit until the next visit. They are now enforced as captures roll over, with the app closed.
- **Capture detail applies right away.** Switching between metadata-only and full-payload capture no longer waits for the next session; it starts a new capture file immediately, and the Captures list shows it.
- **A live view that stays live.** The dashboard re-attaches to the live feed when you come back to the app, so it can no longer sit silently at zero after iOS has restarted the monitor in the background.
- **A connection's details stop being a snapshot.** Pull to refresh on an open connection re-reads its byte counts and duration instead of showing what was true when you tapped it.
- **Search stops claiming there is nothing.** A search that has only scanned part of your history now offers to *keep looking* rather than announcing "no matches".
- **Accessibility.** The timeline's time axis can be walked and swept with VoiceOver — one interval at a time, or a stretch between two ends — the first-run introduction can be navigated and jumped to the end, and the dense screens re-flow at the largest accessibility text sizes instead of truncating or overlapping.
- **Every word in one place.** All of the app's wording now comes from a single catalog rather than being built inside screens, which is what makes translation possible later.

### Landed in July

- **The full app took shape:** a live dashboard, the connection timeline, the connection inspector, the packet screen, capture management, and settings.
- **First run explains itself.** A short, skippable introduction covers what TunnelVision does and what it will ask for before iOS asks for anything, and it can be brought back from Settings.
- **Guided certificate setup.** Enabling HTTPS inspection is a step-by-step flow that hands you an installable profile, tracks how far you have got by asking the system rather than counting taps, and is reversible at every point — including regenerating the certificate, which replaces the old one rather than leaving a second trusted root behind.
- **Timeline filters and the time axis.** Filter by host, protocol, encryption status, or time range; the activity axis above the list narrows and zooms into a moment.
- **Captures you can manage.** Share a `.pcap`, start a new capture file without stopping monitoring, and delete old ones — with the file currently being recorded protected, and the consequences of a deletion spelled out first.
- **JSON export of your connection list**, with a summary of exactly how much it holds and what it does *not* include shown before anything is shared.
- **Storage settings.** Choose how much of each packet is kept and set retention limits by age and by size, with current usage shown.

