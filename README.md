# TunnelVision

**See exactly what your iPhone is talking to — a private network monitor that runs entirely on your device. No jailbreak, no computer, nothing ever leaves your phone.**

TunnelVision shows you every connection your iPhone or iPad makes: which apps reach which servers, on what ports, and how much data they move — live, as it happens. If you want, you can also look inside your own HTTPS traffic to debug and audit what your apps really send. All of it happens on the device; there is no server behind TunnelVision and no account to create.

## Your privacy comes first

TunnelVision is built to inspect **your own** traffic, and its design deliberately stops there:

- **Nothing leaves your device.** All capture, storage, and analysis stay in the app. There is no cloud, no account, and no upload — TunnelVision has no server to send anything to.
- **You are always in control.** Monitoring only runs while you have the tunnel switched on, and iOS shows the standard VPN indicator the whole time.
- **Looking inside HTTPS is opt-in.** Reading encrypted traffic is off by default. Turning it on requires *you* to install a certificate on your device — a deliberate, reversible step, guided inside the app.
- **It won't break other apps.** Apps that pin their certificates simply stay private and are shown as *not inspectable*. TunnelVision respects other apps' security and never tries to defeat it.

## What you can do with it

- **Watch traffic live.** A dashboard of real-time throughput and an interactive timeline of every connection.
- **Inspect a connection.** Tap any entry to see the host, ports, timing, and data volume — and, for inspected HTTPS or plaintext, the actual request and response.
- **Audit an app's behaviour.** Find out who an app is really contacting, including quiet background activity.
- **Export for later.** Save any capture as a standard `.pcap` file to open in Wireshark or `tcpdump`, or share a connection list as JSON.

## How to use it

1. **Start monitoring.** Open TunnelVision and tap *Start*. iOS will ask you to allow a VPN configuration — this is how on-device traffic monitoring works on iPhone, and it stays entirely local. The dashboard starts filling in immediately.
2. **Explore.** Watch the live throughput, scroll the timeline, and tap any connection to open its details.
3. **Look inside HTTPS (optional).** Go to *Settings → TLS inspection*, generate the certificate, and follow the on-screen steps to install and trust it in **Settings → General → VPN & Device Management** and **Certificate Trust Settings**. Your own HTTPS traffic becomes readable; apps that pin their certificates stay private.
4. **Export.** Share a capture as `.pcap` or a flow list as JSON from the share button.

You can stop monitoring at any time, and you can remove the inspection certificate from iOS Settings whenever you like.

## What you need

- An **iPhone or iPad running iOS 17 or later**.
- Nothing else. Looking inside HTTPS additionally asks you to install a certificate profile — an in-app, guided, fully reversible step.

## How it works

TunnelVision uses Apple's built-in **NetworkExtension** framework to run a small, *local* VPN — one that ends on your own phone instead of forwarding to a company's server somewhere. Your traffic passes through it, TunnelVision records what it sees, and the traffic continues to the internet unchanged. Latency-sensitive traffic such as calls and video streaming is passed straight through so your phone stays fast and your battery is spared.

## Questions

- **Why does it need VPN permission?** Capturing traffic on iOS is only possible through a VPN interface. TunnelVision's is local-only — your data is not routed to TunnelVision or anyone else.
- **Does my data go anywhere?** No. Everything stays on your device.
- **An app's HTTPS shows "not inspectable" — is something broken?** No. That app pins its certificates, and TunnelVision intentionally leaves it alone rather than interfering with its security.
- **Will it drain my battery?** It is built to be light: streaming and call traffic is passed through without heavy processing, and captures are written straight to storage instead of piling up in memory.

## License

Released under the [MIT License](LICENSE). © 2026 juanmmm21.
