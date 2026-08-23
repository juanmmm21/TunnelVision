# TunnelVision

**See exactly what your iPhone is talking to — a private network monitor that runs entirely on your device. No jailbreak, no computer, nothing ever leaves your phone.**

TunnelVision shows you every connection your iPhone or iPad makes: which apps reach which servers, on what ports, and how much data they move — live, as it happens. You can follow a connection all the way down to the individual packets and their raw bytes, and save any capture as a standard `.pcap` file. All of it happens on the device; there is no server behind TunnelVision and no account to create.

## See it

| ![The dashboard, with live throughput and the busiest hosts](docs/screenshots/dashboard.png) | ![The timeline of every recorded connection](docs/screenshots/timeline.png) | ![One connection, with its packets listed underneath](docs/screenshots/connection.png) |
|:--:|:--:|:--:|
| **Live traffic**, in and out, and who is talking most right now | **Your history**, newest first, and whether each connection was encrypted | **One connection**, packet by packet |

| ![A packet screen showing a decoded DNS reply](docs/screenshots/packet.png) | ![Decrypted HTTPS shown turn by turn](docs/screenshots/decrypted.png) | ![The captures list with the room left on the device](docs/screenshots/captures.png) |
|:--:|:--:|:--:|
| **One packet**, headers decoded — here a DNS reply, with the name looked up and the answer | **Inside your own HTTPS**, turn by turn, when you switch it on | **Your capture files**, and whether they are going to fill your phone |

TunnelVision follows the system appearance, so all of it comes in dark too:

<img src="docs/screenshots/dashboard-dark.png" width="260" alt="The dashboard in dark mode">

## Your privacy comes first

TunnelVision is built to inspect **your own** traffic, and its design deliberately stops there:

- **Nothing leaves your device.** All capture, storage, and analysis stay in the app. There is no cloud, no account, and no upload — TunnelVision has no server to send anything to. The only time a file of yours can leave is when *you* share a capture, and the app tells you what is inside it before the share sheet opens.
- **You are always in control.** Monitoring only runs while you have the tunnel switched on, and iOS shows the standard VPN indicator the whole time.
- **Looking inside HTTPS is opt-in.** Reading encrypted traffic is off by default. Turning it on requires *you* to install a certificate on your device — a deliberate, reversible step, guided screen by screen inside the app, and undoable from the same place.
- **It won't break other apps.** Apps that pin their certificates simply stay private and are shown as *not inspectable*. TunnelVision respects other apps' security and never tries to defeat it.

## What you can do with it

- **Watch traffic live.** Real-time throughput in and out, the hosts talking the most right now, and how many connections are active this session.
- **Scroll through your history.** Every connection, newest first, with the host, ports, data moved, duration, and whether it was plaintext, encrypted, inspected, or not inspectable. Filter by host, protocol, encryption status, or time range.
- **Jump to a moment.** A time axis above the history shows activity interval by interval; tap one to narrow the list to it, and keep tapping to zoom in.
- **Open a connection.** Every packet it carried, titled by what it meant for the connection — opened, accepted, data, delivery confirmed, finished, cut off — with the timing of each one relative to the connection's first packet.
- **Read a single packet.** Its headers, decoded into plain terms (endpoints, protocol, sequence and acknowledgment numbers, window), plus the raw bytes as hex and ASCII, ready to copy or share. For a DNS lookup it goes one layer further and tells you the name that was queried and what answered.
- **Look inside your own HTTPS.** Optional, off by default, and yours to switch on: a connection you inspected shows the exchange decoded, turn by turn. Apps that pin their certificates stay private.
- **Export for later.** Save any capture as a standard `.pcap` file to open in Wireshark or `tcpdump`, or export your connection list as JSON.
- **Keep storage in check.** Set how long history is kept and how large captures may grow; the limits are enforced while monitoring runs, not only while you are looking. The captures list tells you the room left against those limits and when the oldest one expires.

## How to use it

1. **Start monitoring.** Open TunnelVision — a short introduction explains what it does and what it will ask for — and tap *Start monitoring*. iOS will ask you to allow a VPN configuration; this is how on-device traffic monitoring works on iPhone, and it stays entirely local. The dashboard starts filling in immediately.
2. **Explore.** Watch the live throughput, scroll the timeline, and tap any connection to open it, then any packet to see its bytes.
3. **Look inside HTTPS (optional).** Go to *Settings → set up secure traffic inspection*. The app generates a certificate, hands you the profile, and walks you step by step through installing it and enabling trust in **Settings → General → VPN & Device Management** and **Certificate Trust Settings** — telling you in advance about the warnings iOS will show. Apps that pin their certificates stay private.
4. **Export.** Share a capture as `.pcap` from *Captures*, or export your connection list as JSON — you see how much it contains before anything is shared.

You can stop monitoring at any time, and you can regenerate or remove the inspection certificate from inside the app or from iOS Settings whenever you like.

## What you need

- An **iPhone or iPad running iOS 17 or later**.
- Nothing else. Looking inside HTTPS additionally asks you to install a certificate profile — an in-app, guided, fully reversible step.

## How it works

TunnelVision uses Apple's built-in **NetworkExtension** framework to run a small, *local* VPN — one that ends on your own phone instead of forwarding to a company's server somewhere. Your traffic passes through it, TunnelVision records what it sees, and the traffic continues to the internet unchanged. Latency-sensitive traffic such as calls and video streaming is passed straight through so your phone stays fast and your battery is spared.

## Updates

What has landed recently, in the order it arrived.

**August 2026**

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

**July 2026**

- **The full app took shape:** a live dashboard, the connection timeline, the connection inspector, the packet screen, capture management, and settings.
- **First run explains itself.** A short, skippable introduction covers what TunnelVision does and what it will ask for before iOS asks for anything, and it can be brought back from Settings.
- **Guided certificate setup.** Enabling HTTPS inspection is a step-by-step flow that hands you an installable profile, tracks how far you have got by asking the system rather than counting taps, and is reversible at every point — including regenerating the certificate, which replaces the old one rather than leaving a second trusted root behind.
- **Timeline filters and the time axis.** Filter by host, protocol, encryption status, or time range; the activity axis above the list narrows and zooms into a moment.
- **Captures you can manage.** Share a `.pcap`, start a new capture file without stopping monitoring, and delete old ones — with the file currently being recorded protected, and the consequences of a deletion spelled out first.
- **JSON export of your connection list**, with a summary of exactly how much it holds and what it does *not* include shown before anything is shared.
- **Storage settings.** Choose how much of each packet is kept and set retention limits by age and by size, with current usage shown.

## Questions

- **Why does it need VPN permission?** Capturing traffic on iOS is only possible through a VPN interface. TunnelVision's is local-only — your data is not routed to TunnelVision or anyone else.
- **Does my data go anywhere?** No. Everything stays on your device.
- **An app's HTTPS shows "not inspectable" — is something broken?** No. That app pins its certificates, and TunnelVision intentionally leaves it alone rather than interfering with its security.
- **A packet says its bytes are gone. Why?** Either the capture was set to keep headers only, which you can change in Settings, or the capture file it lived in has been deleted. The connection itself stays in your history either way.
- **Will it drain my battery?** It is built to be light: streaming and call traffic is passed through without heavy processing, and captures are written straight to storage instead of piling up in memory.

## License

Released under the [MIT License](LICENSE). © 2026 juanmmm21.
