# UX — Principles

TunnelVision is a power tool that must feel calm and trustworthy to a non-expert. The
underlying capability (running a VPN, decrypting your own HTTPS) is exactly the kind of thing
that scares users when done badly. These principles keep it friendly.

## 1. Trust is the product

The user is granting an app the ability to see their traffic. Every screen should reinforce
that this is *their* data, staying on *their* device.

- Say plainly, early and often: **nothing leaves your device**.
- Never show a scary system prompt without first explaining, in the app, why it's coming and
  what it means.
- The VPN indicator in the status bar is a feature, not a wart — acknowledge it ("iOS shows a
  VPN icon while monitoring is on").

## 2. Consent is explicit and reversible

- Sensitive capabilities are **off by default** (especially TLS inspection).
- Before any irreversible-feeling step (approve VPN, install a certificate), show a short,
  human explanation and a clear way to *not* do it.
- Every sensitive thing can be undone from the app or from iOS Settings, and the app says how.

## 3. Plain language over jargon

- The end user sees "connections", "apps", "data used", "look inside secure traffic" — not
  "5-tuple", "TCP reassembly", or "MITM". (Those words live in the developer docs, not the UI.)
- A curious user can drill into detail; a casual user never has to.

## 4. Live, but never overwhelming

- The dashboard updates in real time but stays legible: aggregated throughput and a readable
  timeline, not a firehose of raw packets.
- Under heavy traffic the UI degrades gracefully (sampling/coalescing), matching the
  extension's back-pressure. A dropped-records indicator is honest, not alarming.

## 5. Fast and light

- The app must feel instant even with a large history — pagination, lazy loading, and indexed
  queries (see [`../spec/persistence.md`](../spec/persistence.md)).
- Respect the battery story: the UI communicates that streaming/VoIP is passed through untouched.

## 6. Accessible by default

- Full Dynamic Type support; nothing breaks at the largest sizes.
- VoiceOver labels on charts and the timeline (values, not just "chart").
- Sufficient contrast in both light and dark; never rely on color alone (status uses icon +
  label + color).
- Respect Reduce Motion.

## 7. Honest empty and error states

- Empty states teach ("Start monitoring to see connections here").
- Errors are actionable ("Couldn't start the VPN — check that the profile is allowed in
  Settings"), never a raw error code.

## Tone

Direct, calm, competent. No marketing filler, no fear-mongering, no dark patterns. The app
respects the user's intelligence and their data.
