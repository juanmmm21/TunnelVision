# Spec — Audit model (`Shared/Audit`, schema `v6`)

The data model of the TR-03161 network evidence workflow: what is audited, each recording of it, and
the instants marked inside a recording, the classifier that turns a recording's flows into
findings (§ *Findings*), and the comparison of two recordings of the same project (§ *Release
diff*). Scope and attribution method:
[`../decisions/0008-tr03161-audit-workflow-scope.md`](../decisions/0008-tr03161-audit-workflow-scope.md).

The value types live in `Shared/Audit`; their storage is the audit half of `FlowStore`
(`Shared/Persistence/FlowStore+Audit.swift`), in the same database as the history
([`persistence.md`](persistence.md)).

## Two things are called "session"

| | Capture session | Audit session |
|---|---|---|
| What it is | The instant a `FlowStore` was opened | A recording a person starts, names and ends |
| Column | `flows.session` | `flows.audit_session_id` |
| Why it exists | So a recycled 5-tuple is not merged into one flow | So a flow can be reported as evidence of one audit |
| How many | One per tunnel start | At most one open at a time, most traffic belongs to none |

An audit session can span several capture sessions (the tunnel restarts in the middle) — which is why
it is a column of its own and not a reuse of the existing one.

## Types

```swift
/// An allowlist pattern: an exact name or `*.suffix`. Normalised and validated on construction.
public struct DomainPattern: Sendable, Hashable {
    public enum Scope: Sendable, Hashable { case exact, subdomains }
    public enum ParseError: Error, Sendable, Equatable {
        case empty, misplacedWildcard, nonASCII, emptyLabel
        case labelTooLong(String), nameTooLong, invalidCharacter(Character)
    }
    public let scope: Scope
    public let name: String                       // normalised, without the `*.` prefix
    public init(parsing text: String) throws
    public var text: String                       // canonical form: what is stored and shown
    public func matches(_ host: String) -> Bool
}

public struct AllowlistEntry: Sendable, Hashable {
    public let pattern: DomainPattern
    public let note: String?                      // "backend", "crash reporting" — goes to the report
}

public struct AuditProject: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let name: String
    public let bundleIdentifier: String?          // informational, never filters traffic
    public let catalogueVersion: String?          // nil until a requirement catalogue is chosen
    public let allowlist: [AllowlistEntry]        // in the order it was written
    public let createdAt: Date
    public func allowlistEntry(matching host: String) -> AllowlistEntry?
}

public struct AppRelease: Sendable, Hashable { public let version: String; public let build: String }

public enum AuditSessionKind: Sendable, Hashable {
    case baseline                                 // recorded without the audited app
    case audit(AppRelease)
    public var release: AppRelease? { get }
}

public struct AuditEnvironment: Sendable, Hashable {
    public let deviceModel: String
    public let osVersion: String
    public let toolVersion: String
}

public struct InspectionConditions: Sendable, Hashable {
    public let inspectionEnabled: Bool
    public let caTrusted: Bool
    public var supportsPinningEvidence: Bool { get }   // both, or pinning is not assessed
}

public struct AuditSession: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let projectID: Int64
    public let kind: AuditSessionKind
    public let environment: AuditEnvironment
    public let inspection: InspectionConditions
    public let startedAt: Date
    public let endedAt: Date?                     // nil while open
    public let notes: String
    public var isOpen: Bool { get }
}

public enum SessionMarkerKind: Sendable, Hashable {
    case consentGiven, loggedIn, loggedOut, custom(String)
}

public struct SessionMarker: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let sessionID: Int64
    public let date: Date
    public let kind: SessionMarkerKind
}

/// The open session with its project's name: what a system control needs to say where it would mark.
public struct AuditRecording: Sendable, Hashable {
    public let session: AuditSession
    public let projectName: String
}

public enum OpenSessionMarkerOutcome: Sendable, Hashable {
    case placed(SessionMarker, in: AuditRecording)
    case noOpenSession
}
```

`AuditProjectDraft` and `AuditSessionDraft` carry everything but what the store assigns (the row id
and the instant, which is always passed in explicitly).

### Rules that are not obvious

- **`*.example.com` does not match `example.com`.** It is the certificate-wildcard convention, and the
  opposite would make allowing a third party's subdomains silently allow its apex too. It does match
  at any depth (`a.b.example.com`), and the comparison is on labels, not on text: `notexample.com`
  does not match.
- **A pattern must be ASCII.** Observed names come from DNS and SNI, where an IDN arrives as `xn--`
  ([`packet-parsing.md`](packet-parsing.md) § *Above L4*); a Unicode pattern would never match
  anything, which in an allowlist is a silent hole. It is rejected so it gets written in punycode.
- **Underscores are accepted** in a label. They are not valid in a hostname but real DNS names carry
  them, and the allowlist is compared against what was observed.
- **A baseline has no release.** It is recorded without the audited app (ADR 0008), so the case cannot
  carry a version — which also keeps a baseline out of a release diff by construction.
- **`supportsPinningEvidence` is the only place the pinning precondition is stated.** Without
  inspection there is no handshake against the local CA; with the CA untrusted *every* app rejects it,
  pinned or not. In both cases `notInspectable` says nothing about the app.

## Schema `v6`

```
audit_projects   id, name, bundle_id?, catalogue_version?, created_at
audit_allowlist  id, project_id → audit_projects (cascade), position, pattern, note?
                 UNIQUE (project_id, pattern)
audit_sessions   id, project_id → audit_projects (cascade), kind, app_version?, build_number?,
                 device_model, os_version, tool_version, inspection_enabled, ca_trusted,
                 started_at, ended_at?, notes
                 UNIQUE INDEX audit_sessions_single_open ((ended_at IS NULL)) WHERE ended_at IS NULL
audit_markers    id, session_id → audit_sessions (cascade), ts, kind, label?
flows            + audit_session_id? → audit_sessions (SET NULL)
                 INDEX flows_audit_session (audit_session_id, first_seen)
```

Instants are nanoseconds since the epoch, like everywhere else on disk. `kind` columns are integers
whose meaning lives in `AuditSerialization`, not in the types: they are disk format.

- **At most one open session, enforced by the schema.** `upsertFlow` tags with "the open session";
  with two, that phrase means nothing. Two processes write this database, so the rule is a partial
  unique index and not only a check in code. The check in code exists too, to report *which* session
  is in the way.
- **Deleting an audit session removes the tag, not the history** (`SET NULL`). The flow happened
  regardless.
- **`clearAll()` leaves projects and sessions in place.** It empties the traffic history, not the work
  of setting up an audit; the sessions simply have no flows left.

## Which session a flow belongs to

`upsertFlow` reads the open audit session **from the database, in the same statement** that writes the
flow. The app opens a session by inserting a row; the extension needs no message telling it so, because
the shared database already is that message.

- A flow first written while a session is open is tagged with it.
- A flow that began **before** the session and is flushed again during it is tagged then: it carried
  traffic during the session, and leaving it out would hide an open connection from the report.
- A tagged flow **never changes session**, even if it outlives its own and another one starts.
- A flow that never had traffic while a session was open belongs to none.

## Which capture files belong to a session

Capture files do not carry the session anywhere. It is **derived**:
`captureFileSequences(inAuditSession:)` returns the files the session's packets point at. A `.pcap`
rotates by size, not by session, so one file can hold traffic from inside and outside a session; a tag
on the file would be the same fact said twice and wrong half of the time. Slicing a capture to the
session is the evidence bundle's job.

## Retention

**Audit evidence is exempt from the storage limits until its session is deleted.** The limits in
Settings → Storage default to one week and 1 GB, and they are applied with nobody watching — by the
extension every time the capture rotates. An audit session recorded on a Monday and exported the week
after would have lost its traffic in between.

- **Connections.** `FlowStore.prune(before:)` skips every flow that carries an audit session, open or
  ended.
- **Capture files.** `auditEvidenceFileSequences()` returns the files that hold bytes of *any* session;
  `RetentionPlanner` never puts them in a plan, by age or by size
  ([`app-services.md`](app-services.md) § *Storage manager*). The whole file is kept, including the
  traffic from outside the session it may also hold — a `.pcap` cannot be trimmed in place.
- **What ends the exemption is deleting the session** (`deleteAuditSession`) or its project. The flows
  lose their tag, become ordinary history, and the next cleanup treats them and their files like
  anything else. Ending a session does not: an ended session is exactly the one waiting to be exported.
- **When the size limit cannot be met because of evidence, that is said**, with its own cause
  (`sizeCapHeldByEvidence`) and its own sentence on both screens that report it. The limit stays unmet;
  evidence is not sacrificed to it.
- **If the evidence cannot be read, nothing is cleaned up.** Both the app and the extension stop the
  cleanup rather than plan without the list.

Three things this deliberately does **not** cover:

- **Decrypted content still expires on its own schedule**
  ([ADR 0007](../decisions/0007-decrypted-content-retention.md)). It is not part of the evidence
  bundle unless explicitly chosen, and a session of a medical app is the last place to keep it longer
  than promised.
- **What the user deletes by hand is still deleted**: a capture removed on the Captures screen, or
  *Delete everything* in Settings (`clearAll()` keeps projects and sessions, and empties them). The
  exemption is from the automatic sweep, not from the owner of the device.
  **But neither does it happen unsaid** (2026-10-05): both confirmations name the evidence before it
  goes. Deleting one capture asks the history whether it holds packets of an audit session
  (`CaptureEvidenceStanding`: `held` / `none` / `unknown`) and, when it does, opens with that — the
  session keeps its connections, its packets can no longer be exported; when the history cannot be
  read it says it cannot tell, rather than implying there is nothing to lose. *Delete everything*
  counts the connections that belong to any session (`FlowStore.auditFlowCount`, carried in
  `StorageUsage`) and says that the sessions stay with nothing left to export. They are the only two
  places where evidence can be lost, since the sweep never takes it.
- **A capture file with no successor is not aged out anyway**, evidence or not — the planner's
  existing rule.

## Store API

```swift
public enum AuditStoreError: Error, Sendable, Equatable {
    case emptyProjectName
    case duplicateAllowlistPattern(String)
    case projectNotFound(Int64)
    case sessionNotFound(Int64)
    case sessionAlreadyOpen(Int64)        // carries the session in the way
    case sessionAlreadyEnded(Int64)
    case dateBeforeSessionStart           // an end or a marker dated before the session began
    case emptyMarkerLabel
}

extension FlowStore {
    public func createAuditProject(_ draft: AuditProjectDraft, at date: Date) throws -> AuditProject
    public func auditProjects() throws -> [AuditProject]                       // newest first
    public func auditProject(id: Int64) throws -> AuditProject?
    public func updateAuditProject(id: Int64, with draft: AuditProjectDraft) throws -> AuditProject
    public func deleteAuditProject(id: Int64) throws

    public func startAuditSession(_ draft: AuditSessionDraft, at date: Date) throws -> AuditSession
    public func endAuditSession(id: Int64, at date: Date) throws -> AuditSession
    public func deleteAuditSession(id: Int64) throws                           // open or ended
    public func openAuditSession() throws -> AuditSession?
    public func auditSession(id: Int64) throws -> AuditSession?
    public func auditSessions(forProject projectID: Int64) throws -> [AuditSession]   // newest first

    public func addMarker(_ kind: SessionMarkerKind, toSession id: Int64, at date: Date) throws -> SessionMarker
    public func addMarkerToOpenSession(_ kind: SessionMarkerKind, at date: Date) throws -> OpenSessionMarkerOutcome
    public func auditRecording() throws -> AuditRecording?                     // the open session, named
    public func markers(forSession id: Int64) throws -> [SessionMarker]        // as they happened

    public func flows(inAuditSession id: Int64, limit: Int) throws -> [StoredFlow]    // oldest first
    public func flowCount(inAuditSession id: Int64) throws -> Int
    public func captureFileSequences(inAuditSession id: Int64) throws -> Set<UInt32>
    public func auditEvidenceFileSequences() throws -> Set<UInt32>             // of every session
}
```

- `updateAuditProject` **replaces** the allowlist rather than patching it: its order is part of what is
  stored, and a draft already carries the list as it should end up. The rules are the ones of creation.
  Sessions are untouched, so an old session is read against today's allowlist — which is what makes two
  releases comparable.
- `deleteAuditSession` takes the markers with it and leaves the flows untagged, like deleting a project
  does. Deleting the open session is also what stops the tagging.
- `auditEvidenceFileSequences()` is one query and not a union of `captureFileSequences(inAuditSession:)`
  because the sweep needs one answer taken at one instant.

- A marker needs an **open** session. On a closed one it is an error, not a late correction: a marker
  placed after looking at the traffic is no longer an observation.
- `flows(inAuditSession:)` is ordered by `first_seen` **ascending**, the opposite of `recentFlows`.
  The Timeline is read from now backwards; evidence is read as it happened.
- Domain-rule violations throw `AuditStoreError`; an unreadable row throws `StoreError.corruptRow`.

## Marking from outside the app

A marker has to be droppable **without leaving the audited app**: the assessor is in the middle of
its onboarding, and coming back to TunnelVision to tap a button changes what is being measured. Three
doors do it, and they are the same App Intent (`PlaceAuditMarkerIntent`, `TunnelVision/Intents`), so
none of them can mark differently from the others:

| Door | Where it lives | Runs in |
|---|---|---|
| Control Center control, Action Button, Lock Screen | `AuditControls` (WidgetKit extension, iOS 18+) | the extension or the app |
| App Shortcut (Shortcuts, Spotlight) and Siri | the app (`AuditShortcuts`) | the app, in the background |

**Which process runs the intent does not matter, by construction.** The intent needs one thing — the
shared database — and both the app and the widget extension have the App Group. It therefore does
not go through `AuditLibrary` (which belongs to the app) but through `OpenSessionMarking`, which
opens the store per call. `AuditControls` has no other entitlement: no Network Extension, no keychain.

The rules:

- **The marker goes to whichever session is open, in one transaction.**
  `addMarkerToOpenSession` reads the open session and writes the marker in the same write. The app
  can end the session from another process between the two; done in two steps, the marker would land
  in a session that had just ended or fail with an error that does not say what happened.
- **No open session is an outcome, not an error — and it is never silent.** The intent cannot open a
  session (that needs a version and a build). The store answers `.noOpenSession`, and the intent ends
  with an error whose sentence says nothing was placed. A marker that was not placed and that the
  assessor believes placed is worse than a failure.
- **Only a written marker produces a confirmation.** `AuditMarkerIntentCopy.reading` maps the three
  reports — placed, no open session, not placed (the database did not answer, or refused the marker)
  — to one confirmation and two errors. The confirmation names the marker, the time **to the second**
  and the project: that is what lets it be matched against what was happening in the audited app.
- **The instant is the gesture's.** It is taken on the first line of `perform()`, before the database
  is opened, like the *Mark now* buttons take theirs at the tap.
- **Only the three fixed markers are offered** (`AuditMarkerOption`). The free-form one needs typing,
  which cannot be done mid-onboarding without the instant ceasing to be the gesture's; it stays on the
  session screen. App Intents extracts its copy at compile time and accepts only literals, so the
  three names are written a second time there; a test holds them equal to the session screen's, and
  fails if a fixed marker is added without its option.
- **The control says where it would mark before it is pressed.** A control does not show its intent's
  error, so its second line carries the state — the recording project's name, *No session recording*,
  or *History unavailable* (`AuditMarkerControlState`). "No session" and "could not read" are told
  apart: the second cannot promise that nothing is recording. The control is configurable — consent
  by default, since that is the marker behind *activity before consent* — so an assessor can add one
  per marker.
- **The app tells the control when to re-read**, on every change of the recording session
  (`AuditControlRefresh`), and **re-reads itself when it comes back to the foreground**
  (`AuditViewModel.resume`): a marker placed from outside is written without passing through the view
  model, and an assessor who returns to the session screen and does not see it would read that as
  *not placed*.

The control exists from iOS 18, and the app's deployment target is 17. The extension target carries
its own deployment target instead of availability checks on every type: on iOS 17 it is simply not
offered, and the App Shortcut still is.

## From the app

The app reaches all of this through `AuditLibrary` (`TunnelVision/Services`), an actor that opens the
store per operation — like `StorageManager`, and for the same reasons — and classifies what it throws
into `AuditLibraryError`: a **rule** the screen can do something about (`AuditStoreError`) or a
**history** that did not answer. The screens are described in [`../ux/audit.md`](../ux/audit.md).

What a session declares about its recording is not typed by anyone: `AuditRecordingConditions` reads
the hardware model identifier (the simulated one on a Simulator, where `uname` reports the Mac's
architecture), the system version and the tool version, and derives `InspectionConditions` from the
saved settings and the trust evaluation of the CA. Settings that cannot be read count as inspection
**off**, which is what the extension does with them.

`-TVSeedFixture` seeds one project (`AuditFixture`, Debug-only) with a baseline and an audit session,
both ended, each tagged with a quarter of the synthetic flows by the same path the extension takes —
the session is open while its flows are written.

## Findings

`FindingsClassifier` (`Shared/Audit`) turns the flows of a session into what they prove. It is pure —
it reads neither the history nor the clock — and it does **not** decide verdicts: whether a finding
breaks a requirement is the catalogue's rule. It only states what the flows allow to be stated, and
what could not be looked at comes back with its reason instead of being left out.

```swift
public enum FindingKind: String, Sendable, Hashable, Codable, CaseIterable {
    case weakTLSVersion                       // the raw value is what a catalogue refers to
    case cleartextTraffic
    case hostNotInAllowlist
    case unnamedFlow
    case pinningAbsent
    case pinningObserved
    case activityBeforeConsent
}

public enum FindingEvidence: Sendable, Hashable {
    case weakTLSVersion(TLSVersionObservation)
    case cleartextTraffic(CleartextProtocol)
    case hostNotInAllowlist(host: String)     // normalised
    case unnamedFlow(UnnamedFlowReason)
    case pinningAbsent(host: String)          // normalised
    case pinningObserved(host: String)        // normalised
    case activityBeforeConsent                // nothing: the instant belongs to each flow
    public var kind: FindingKind { get }
}

public struct Finding: Sendable, Hashable {
    public let evidence: FindingEvidence      // what is stated
    public let flowIDs: [Int64]               // the flows that prove it, as they happened; never empty
}

public struct CheckCoverage<Gap>: Sendable, Hashable {
    public let satisfiedFlowIDs: [Int64]              // looked at, nothing to report
    public let unassessed: [UnassessedFlows<Gap>]     // applicable, could not be looked at: why
    public let notApplicableFlowIDs: [Int64]          // not what this check looks at
}

public struct FindingsPolicy: Sendable, Hashable {
    public let minimumTLSVersion: TLSProtocolVersion
    public init?(minimumTLSVersion: TLSProtocolVersion)   // nil unless a published version
}

public struct SessionFindings: Sendable, Hashable {
    public let findings: [Finding]
    public let tlsVersion: CheckCoverage<TLSVersionGap>
    public let encryption: CheckCoverage<EncryptionGap>
    public let host: CheckCoverage<HostGap>
    public let pinning: CheckCoverage<PinningGap>     // satisfied is always empty
    public let consent: CheckCoverage<ConsentGap>
}

public enum FindingsClassifier {
    public static func classify(
        flows: [StoredFlow], project: AuditProject,
        session: AuditSession, markers: [SessionMarker],
        policy: FindingsPolicy
    ) -> SessionFindings
}
```

- **A finding is a statement, and the flows are its proof.** Flows that prove exactly the same thing
  are one finding with several flows. Nothing that belongs to a flow — its instant, its address — is
  in the evidence: it is read from the flows the finding points at. The one exception is the host of
  `hostNotInAllowlist` and of the two pinning kinds, which is the statement itself. Packets are
  reached through the flow, and from there to the file and offset of their bytes.
- **Order is the order things happened.** Findings and reasons appear in the order of their first
  flow; the report's order never depends on a hash. A flow that proves several things gives them as
  cleartext, TLS version, destination, pinning, consent.
- **The project enters for its allowlist and nothing else.** The session enters for its kind and
  its inspection conditions, and of the markers only `consentGiven` is read; a marker of another
  session is ignored.
- **No findings is not the same as nothing wrong.** Each check also returns its coverage, and in
  each check every flow lands in exactly one place: a finding, *satisfied*, *unassessed* with a reason, or *not
  applicable*. A requirement can only be reported as observed without incident when its check has
  satisfied flows; otherwise it is *not assessed by this tool*. **Pinning is the exception in
  shape, not in rule**: its favourable outcome is a finding of its own kind (`pinningObserved`),
  because the report has to name the hosts it was seen on, so that check never has satisfied
  flows and a requirement about pinning reads the two kinds.
- **Thresholds are configuration.** The classifier is given a `FindingsPolicy` and carries no
  threshold of its own. A minimum that is not a published version is refused when the policy is
  built, so a miswritten catalogue is found on loading it.
- **`FindingKind` only has the kinds the classifier produces.** A kind nothing can raise would be a
  line of the report that is always clean without anybody having looked.

### The TLS version of a flow

`TLSVersionAssessment(of:minimum:)` says one of four things about a flow: `weak`, `acceptable` (both
with a `TLSVersionObservation`: the version **and where it came from**), `notAssessed` with a
`TLSVersionGap`, or `notApplicable`.

| What the flow carries | Result |
|---|---|
| A ServerHello reading below the minimum | `weak`, basis `serverHello` |
| A ServerHello reading at or above it | `acceptable` — what the client offered does not qualify it |
| An upstream reading below the minimum | `weak`, basis `upstreamConnection` |
| An upstream reading at or above it, and the app's ClientHello **listed** its versions, all published and none below the minimum | `acceptable`, basis `upstreamConnection` |
| An upstream reading at or above it, anything else | `notAssessed(.appNegotiationNotObserved)` with the reason the offer does not settle it |
| A version that is not one of the five published | `notAssessed(.unrecognisedVersion)` |
| An alert instead of a ServerHello | `notAssessed(.serverRefused)` |
| QUIC v1 or v2 read from the **server** | TLS 1.3, basis `quic` |
| QUIC read only from the client | `notAssessed(.quicVersionOnlyProposed)` |
| A QUIC version not known to carry TLS 1.3 | `notAssessed(.unrecognisedQUICVersion)` |
| No reading, but the status is not `plaintext` or a ClientHello was read | `notAssessed(.serverAnswerNotRead)` |
| No reading and no sign of TLS or QUIC | `notApplicable` |

- **An upstream reading answers the tunnel's ClientHello, not the app's**
  ([`relay-and-tls.md`](relay-and-tls.md) § *What an inspected flow's server chose*). A weak one is
  still a finding — a server that gives a modern client no more than that gave the app no more
  either — but a good one only says what the server accepts. What the app would have negotiated
  comes from its own offer, and only an exact list with nothing below the minimum rules a weaker
  version out: a `legacy_version` ceiling does not say where the floor is, an offer with Encrypted
  Client Hello may not be the real one, and an empty list or one with unpublished values cannot be
  ordered. Each of those is its own `ClientOfferGap`, so the report can say which.
- **Only published versions are ordered** (`TLSProtocolVersion.isPublished`, SSL 3.0 to TLS 1.3). By
  raw value a TLS 1.3 draft (`0x7F..`) is greater than TLS 1.3; it is neither weak nor acceptable.
- **`serverTLS == nil` is never read as "not TLS".** With any sign of TLS it is a reading that is
  missing. And `notApplicable` is **not** a statement that the flow went in the clear: on TCP the
  status is `encrypted` for port 443 and `plaintext` for every other port *because of the port*
  (`FlowTable.initialTLSStatus`), and the ServerHello is only read on 443. TLS
  on any other port is recognised (it raises the status, so it lands in `serverAnswerNotRead`), but
  its version is not read.

### Whether a flow was encrypted

`EncryptionAssessment(of:)` is the rule behind `cleartextTraffic`. **`cleartext` only comes from an
observation**: the flow's stream was seen to open with a readable HTTP request
(`StreamOpening.httpRequest`, [`relay-and-tls.md`](relay-and-tls.md) § *How a stream opened*).
Neither the port nor `TLSInspectionStatus` is enough for anything — the status of a TCP flow is
born from its port — so what was not seen is `notAssessed` with its reason, never "cleartext" and
never "encrypted".

| What the flow carries | Result |
|---|---|
| A stream that opened with an HTTP request, on any port, whatever the status | `cleartext(.http)` |
| TCP whose stream opened with a TLS handshake, or any reading that only exists if TLS was negotiated (the client's offer, the server's answer, an inspection outcome) | `encrypted(.tls)` |
| TCP whose stream opened with something else | `notAssessed(.unrecognisedOpening)` |
| TCP with no opening read and none of the above — including 443, whose `encrypted` is the port's | `notAssessed(.openingNotRead)` |
| UDP with a QUIC version known to protect its packets, from either end | `encrypted(.quic)` |
| UDP with another QUIC version | `notAssessed(.unrecognisedQUICVersion)` |
| UDP with no QUIC reading — port 443 or not, and DNS on 53 | `notAssessed(.datagramsNotRead)` |
| Anything that is neither TCP nor UDP | `notApplicable` |

- **A session recorded before schema `v14` has no openings**, so its plain TCP flows are
  `openingNotRead`: no cleartext finding and no satisfied flow either. That is correct — nobody
  looked — and it is why the coverage exists.
- **DNS on port 53 is not a `cleartextTraffic` finding.** Today it falls in `datagramsNotRead`
  with every other datagram; a finding of its own needs to know which end of the flow is the
  device, which a stored flow does not say.
- **Only HTTP is recognised as cleartext.** Another unencrypted protocol is `unrecognisedOpening`:
  the report can list those flows, and cannot call them clear.

### Where a flow went

`HostAssessment(of:project:)` is the rule behind `hostNotInAllowlist` and `unnamedFlow`. It reads
the flow's `FlowName` ([`data-model.md`](data-model.md) § *A flow has two names*), never the `sni`
column, and says one of four things: `notInAllowlist(host:)`, `unnamed` with an
`UnnamedFlowReason`, `allowed`, or `notAssessed` with a `HostGap`. **There is no *not applicable***:
every flow went somewhere, so an unnamed flow is not set aside from the check — it is a finding.

| What the flow carries | Result |
|---|---|
| No name, and no ClientHello was read | `unnamed(.noClientHelloRead)` |
| No name, a ClientHello that announced none | `unnamed(.serverNameNotAnnounced)` |
| No name, a ClientHello that announced none and carried Encrypted Client Hello | `unnamed(.encryptedClientHello)` |
| A name, and the project's allowlist is empty | `notAssessed(.allowlistEmpty)` |
| An announced name (SNI) the allowlist covers | `allowed` |
| An announced name it does not cover | `notInAllowlist` |
| A name from DNS, and it and **every** other candidate of the address are covered | `allowed` |
| A name from DNS, and neither it nor any other candidate is covered | `notInAllowlist`, under the attributed name |
| A name from DNS whose candidates fall on both sides | `notAssessed(.candidatesDisagree(attributedNameAllowed:))` |

- **An allowed winner does not clear the address.** A name from DNS is the most recently resolved
  of the names the address had alive, and the flow may have been to any of them
  ([`packet-parsing.md`](packet-parsing.md) § *Names from DNS*). So while the candidates do not all
  say the same, nothing is stated about the flow: it is neither a finding nor a satisfied flow, and
  the gap says on which side the attributed name falls. When every candidate is outside, the flow
  went outside whichever it was, and the finding is filed under the attributed name; the others are
  on the flow.
- **An SNI is not second-guessed.** When the connection announced a name, the resolved one is not
  consulted, to clear it or to doubt it.
- **One finding per host.** The evidence carries the host, normalised
  (`DomainPattern.normalised(host:)`: lower case, no trailing dot), so every connection to the same
  unlisted host is one finding however the name was written and wherever it came from. The origin
  of the name — SNI or DNS — is read from each flow.
- **An empty allowlist is not an allowlist that allows nothing.** A project whose assessor has
  written none has not said what is expected; calling every connection unexpected would state a
  decision nobody took. Named flows are then *unassessed*. Unnamed flows are still reported.
- **The reason of an unnamed flow is what the flow itself shows**, and all three also mean that no
  DNS reply seen by the tunnel had named its address. *There was no DNS to read* (encrypted DNS) is
  **not** one of them: it is a fact of the session, told by tunnel counters that are not stored
  with it, so the report cannot derive it from the flows. An IP literal is not asserted either —
  `serverNameNotAnnounced` is what such a connection looks like, not proof of one.
- **The remote address is not read.** Nothing here needs to know which end of the flow is the
  device, so local-network traffic (mDNS, a router) is unnamed like anything else.

### Whether the app pins

`PinningAssessment(of:conditions:)` is the rule behind `pinningAbsent` and `pinningObserved`. It
bypasses nothing ([ADR 0003](../decisions/0003-no-third-party-pinning-bypass.md)): it **reads** the
outcome the relay already recorded for an inspection attempt
([`relay-and-tls.md`](relay-and-tls.md) § *TLS inspection*). It says one of four things:
`absent(host:)`, `observed(host:)`, `notAssessed` with a `PinningGap`, or `notApplicable`.

| What the flow carries | Result |
|---|---|
| No inspection outcome and no sign of TLS or QUIC — or an HTTP request seen in the clear, whatever the port's status | `notApplicable` |
| Anything else, in a session recorded with inspection off | `notAssessed(.inspectionOff)` |
| Anything else, with inspection on and the CA not trusted | `notAssessed(.caNotTrusted)` |
| `inspected`, with an announced name | `absent`, under that name |
| `notInspectable`, with an announced name | `observed`, under that name |
| `inspected` or `notInspectable` with no announced name | `notAssessed(.outcomeWithoutAnnouncedName)` |
| A QUIC reading and no outcome | `notAssessed(.quicNotInspected)` |
| TLS over TCP and no outcome | `notAssessed(.noInspectionOutcome)` |

- **What each kind states.** `pinningAbsent`: a connection completed its handshake against a
  certificate issued by the local CA, so for that host the app trusts a root the user installed.
  `pinningObserved`: a connection to that host refused that certificate. Neither says *why* —
  an app that refuses may pin, or may simply not accept user-installed roots.
- **The session's conditions gate everything**, in `InspectionConditions.supportsPinningEvidence`
  and nowhere else. With the CA untrusted *every* app refuses, so a refusal is not reported; and
  an `inspected` flow in a session declared without inspection is not reported either — the
  conditions the session was recorded under are then not the ones it declares, and the report
  does not pick which to believe. The reason given is the first that fails, so a QUIC flow in a
  session without inspection says `inspectionOff`.
- **`encrypted` alone is not acceptance.** A flow with no outcome was not a candidate (off 443,
  no announced name), failed for a reason that was not the app, or never closed cleanly. It is
  unassessed, never counted for either kind.
- **`pinningObserved` is a statement about the host, not about each connection.** After the first
  refusal the relay does not try that host again for as long as the tunnel runs
  (`PinnedHostMemory`) and marks the following flows `notInspectable` without testing them. So
  the finding says a connection to the host refused — at least once since the tunnel started,
  which may be before the audit session opened — and it cannot show a second client of the same
  host that would have accepted.
- **A host can have both findings**, when a connection accepted before another refused. Both are
  reported; nothing here reconciles them, because the tunnel does not know which app sent which.
- **The host is the announced one**, normalised like `hostNotInAllowlist`'s. The certificate the
  app accepted or refused was issued for the SNI, so a name deduced from DNS does not stand in
  for it.
- **This check has no satisfied flows.** Both outcomes are findings.
- **A baseline is classified like any session.** Whoever calls decides what its pinning findings
  mean; they are still true of the connections.

### Activity before consent

`ConsentAssessment(of:sessionKind:consent:)` is the rule behind `activityBeforeConsent`. It
compares the flow's **first packet** (`firstSeen`) with the session's `consentGiven` markers,
which arrive as a `ConsentInterval` — the earliest and the latest of them, the same instant when
there is one — and says `beforeConsent`, `afterConsent`, `notAssessed` with a `ConsentGap`, or
`notApplicable`.

| The session and the flow | Result |
|---|---|
| A `baseline` session, with or without markers | `notApplicable` |
| No `consentGiven` marker | `notAssessed(.noConsentMarker)` |
| First packet before the earliest marker | `beforeConsent` |
| First packet at the latest marker or after it | `afterConsent` |
| First packet from the earliest marker on and before the latest | `notAssessed(.betweenConsentMarkers)` |

- **Without a marker there is no "before".** A session nobody marked has neither findings nor
  satisfied flows: that the marker is missing does not mean nothing preceded consent.
- **Several markers only state what all of them say.** Two `consentGiven` markers do not tell
  which one counts — a second tap, a second consent dialog, consent withdrawn and given again —
  and choosing would be deciding it for the assessor. Before all of them is a finding, after all
  of them is satisfied, and in between nothing is stated.
- **What counts is when the connection opened.** A flow that began before consent and kept
  carrying traffic after it is a finding; how long it lasted is on the flow (`lastSeen`). So is
  a flow older than the session itself that carried traffic during it (§ *Which session a flow
  belongs to*).
- **One finding.** The evidence carries nothing — the instant belongs to each flow — so every
  flow opened before consent is the same finding.
- **A baseline has no consent to precede.** It is recorded without the audited app, so all its
  flows are *not applicable*, whatever markers it carries.
- **Whose flow it was is not stated.** A connection of the system opened before the marker is a
  finding like any other; telling it from the app's is what the baseline is for (ADR 0008).

## Release diff

`ReleaseDiff` (`Shared/Audit`) compares two audit sessions of the same project: the domains the
later one contacted that the earlier one did not, the ones it stopped contacting, and what changed
in the TLS of those that remain. Like the classifier it is pure and decides no verdict. It is built
on `SessionDomains`, the inventory of **one** session, which compares nothing.

```swift
public struct DomainObservation: Sendable, Hashable {      // one domain in one session
    public let host: String                                // normalised, as a finding cites it
    public let flowIDs: [Int64]                            // flows that went to it
    public let candidateFlowIDs: [Int64]                   // flows that went to it or to another name
    public let tlsSightings: [TLSVersionSighting]          // versions read in flowIDs, with their source
    public let flowIDsWithoutTLSReading: [Int64]
    public var isSeen: Bool { get }                        // flowIDs is not empty
}

public struct SessionDomains: Sendable, Hashable {
    public let domains: [DomainObservation]                // order of first appearance
    public let unnamedFlowIDs: [Int64]
    public init(flows: [StoredFlow])
}

public enum AllowlistStanding: Sendable, Hashable {
    case listed(AllowlistEntry)                            // the first entry that covers it
    case unlisted
    case allowlistEmpty
}

public enum TLSNegotiator: Sendable, Hashable, CaseIterable { case app, tunnel }
public enum TLSFloorShift: Sendable, Hashable { case lowered, raised, held, notOrdered }
public enum TLSComparisonGap: Sendable, Hashable {
    case notReadInEarlierSession, notReadInLaterSession, notReadInEitherSession
}
public enum TLSVersionComparison: Sendable, Hashable {     // one domain, one negotiator
    case same([TLSProtocolVersion])
    case different(earlier: [TLSProtocolVersion], later: [TLSProtocolVersion], floor: TLSFloorShift)
    case notCompared(TLSComparisonGap)
}

public enum DomainPresence: Sendable, Hashable { case absent, candidateOnly, seen }
public enum DomainStatus: Sendable, Hashable {
    case new
    case gone
    case inBoth(app: TLSVersionComparison, tunnel: TLSVersionComparison)
    case undetermined(earlier: DomainPresence, later: DomainPresence)
}

public struct DomainComparison: Sendable, Hashable {
    public let host: String
    public let standing: AllowlistStanding
    public let earlier: DomainObservation?                 // nil: not in that session
    public let later: DomainObservation?
    public var status: DomainStatus { get }                // derived from the two observations
    public var hasTLSChange: Bool { get }
}

public struct ReleaseDiff: Sendable, Hashable {
    public enum Refusal: Error, Sendable, Hashable {
        case sameSession, differentProjects, notTheSessionsProject
        case baseline(sessionID: Int64)
        case stillOpen(sessionID: Int64)
    }
    public let earlier: AuditSession
    public let later: AuditSession
    public let domains: [DomainComparison]
    public let earlierUnnamedFlowIDs: [Int64]
    public let laterUnnamedFlowIDs: [Int64]
    public init(
        between first: AuditSession, flows firstFlows: [StoredFlow],
        and second: AuditSession, flows secondFlows: [StoredFlow],
        project: AuditProject
    ) throws
    public var newDomains: [DomainComparison] { get }
    public var goneDomains: [DomainComparison] { get }
    public var domainsInBoth: [DomainComparison] { get }
    public var undeterminedDomains: [DomainComparison] { get }
    public var unexpectedNewDomains: [DomainComparison] { get }   // new and unlisted: the headline
    public var domainsWithTLSChange: [DomainComparison] { get }
}
```

### Which two sessions

| The two sessions | Result |
|---|---|
| The same session twice | `sameSession` |
| Of different projects | `differentProjects` |
| Of a project that is not the one given | `notTheSessionsProject` |
| Either is a `baseline` | `baseline(sessionID:)` |
| Either is still open | `stillOpen(sessionID:)` |
| Anything else | a diff |

The reason given is the first that fails, in that order.

- **The later session is the one that started later** (`startedAt`; the greater `id` if they
  coincide). The two are given in either order and the result is the same. Version and build are
  free text and nothing orders `2.4.0 (118)` against `2.4.0-rc1 (2024.3)`; which of two sessions was
  recorded first is known. So an older release recorded afterwards is the *later* side — both
  releases are on the result for the report to print.
- **Two sessions of the same build are compared like any other.** What the diff says then is what
  varied between two runs of one binary.
- **A baseline is refused, not subtracted.** Reading an audit session against its baseline (ADR
  0008) asks whose traffic it was, not what changed between releases, and words its answer
  differently. It is not this type under another name; `SessionDomains` is the part it would share.
- **An open session is refused.** It is still recording, so everything it has not contacted yet
  would come out as *gone*.
- **The flows have to be all of the session's.** A `StoredFlow` does not say which session it
  belongs to and `flows(inAuditSession:limit:)` takes a limit: a truncated list gives domains as
  *gone* or misses new ones, and nothing here can tell.

### What the domain of a flow is

The flow's `FlowName`, never the `sni` column, normalised with `DomainPattern.normalised(host:)` —
the same text a `hostNotInAllowlist` finding cites, so the two can be matched.

| What the flow carries | Where it lands |
|---|---|
| An announced name (SNI) | `flowIDs` of that domain; the resolved names are not consulted |
| A name from DNS with no other candidate | `flowIDs` of that domain |
| A name from DNS whose address had other names | `candidateFlowIDs` of **every** one of them, the attributed one included |
| No name | `unnamedFlowIDs` |

- **A winner does not speak for the other candidates**, as in § *Where a flow went*. A flow to an
  address shared by several names went to one of them and it is not known which, so it proves
  none of them was contacted. The origin of a name — SNI or DNS — is read from each flow.
- **A candidate that only differs in how it is written is not an alternative.**

### What is stated about a domain

| Earlier session | Later session | Status |
|---|---|---|
| absent | seen | `new` |
| seen | absent | `gone` |
| seen | seen | `inBoth`, with its two TLS comparisons |
| candidate only, on either side | anything | `undetermined`, with how it stands on each side |

- **A domain that is only a candidate on one side is not classified.** It may or may not have been
  contacted there, so it is neither new, gone nor kept. The report lists it as such; it does not
  drop it.
- **The headline is new *and* unlisted** (`unexpectedNewDomains`). With an empty allowlist there is
  none — nobody has said what is expected (§ *Where a flow went*) — and an undetermined domain is
  never in it.
- **These are statements about observed names.** `gone` means no flow of the later session carried
  that name; an unnamed flow of that session may have gone exactly there, and a `new` domain may
  have been reached without a name before. That is why the unnamed flows of each side travel with
  the diff: the report prints their count beside the lists.
- **The allowlist is the project's as it is now**, the one both sessions share.
- **Order.** The later session's domains first, in the order they appeared in it; then the ones
  only the earlier session has, in its order.

### TLS changes per domain

Only for a domain seen in both sessions, and only from the flows that went to it: a candidate
flow's version belongs to a connection whose domain is not known. The version of a flow is
`TLSVersionObservation(of:)`, the same reading `TLSVersionAssessment` judges, without a minimum.

- **A version is compared only with those answering the same ClientHello.** A ServerHello read off
  the stream and QUIC (TLS 1.3 by definition) are the **app's** connection; an upstream reading is
  the **tunnel's** ([`relay-and-tls.md`](relay-and-tls.md) § *What an inspected flow's server
  chose*). Each has its own comparison. A session recorded with inspection against one recorded
  without it gives two readings with no counterpart — `notCompared` on both — not a TLS change.
- **What is compared is the set of versions**, not how many connections carried each. The lists
  are in ascending wire value, which among published versions is weakest first.
- **The direction is that of the weakest version** (`TLSFloorShift`), since that is what a
  minimum-version requirement looks at: one weaker connection in the later session is `lowered`.
  When the sets differ and the weakest is the same it is `held`; with any unpublished value on
  either side it is `notOrdered` (§ *The TLS version of a flow*).
- **A flow with no reading is not a version.** A side with none is `notCompared` with which side;
  the flows are in `flowIDsWithoutTLSReading`. A domain that went from TLS to cleartext HTTP is
  therefore *not compared* here — it is the later session's `cleartextTraffic` finding.
- **No threshold enters.** Whether the later floor is acceptable is the classifier's question,
  asked of the later session.

## Tests

- `SessionDomainsTests`: every row of the domain table; the host is normalised and a name from DNS
  with no competition is the same domain as an announced one; a domain can be seen by one flow and
  a candidate of another; unnamed flows are kept apart, an empty SNI included; first-appearance
  order; flows with the same reading are one sighting and another source is another; a candidate
  flow lends its version to no domain.
- `ReleaseDiffTests`: every refusal and the first that fails; the later session is the one that
  started later whatever the order given or the release, by id on a tie; new, gone and in both,
  each with the observations of both sides; the order of the result; the standing against the
  allowlist, the headline, and none without an allowlist; every way a candidate keeps a domain
  from being classified; unnamed flows on each side; the floor lowered, raised, held and not
  ordered; the same set in another order or count is no change; QUIC counts as the app's TLS 1.3;
  an upstream reading is never compared with the app's own and is compared with another upstream
  one; a side with no reading; a new or gone domain has no TLS change.
- `PinningAssessmentTests`: every row of the pinning table; the host is cited normalised; an
  outcome whose flow has only a resolved name, or an empty SNI, is not assessed; the reason of a
  session without inspection or without a trusted CA is the first that fails, and reaches the
  flows with an outcome too; TLS with no outcome is never acceptance, on any port; QUIC from
  either end and of any version; *not applicable* does not depend on the conditions; the gap
  identifiers are stable.
- `ConsentAssessmentTests`: every row of the consent table; the interval is the earliest and the
  latest instant whatever the order of the markers, ignores other kinds — a custom marker named
  like consent included — and other sessions' markers; the first packet decides, for a flow that
  outlived consent and for one older than the session; the instant of the marker itself is
  after; the gap identifiers are stable.
- `HostAssessmentTests`: every row of the table above; a wildcard's own apex is outside; the host
  is cited normalised; an SNI decides alone; an allowed winner does not clear an unlisted candidate
  and an unlisted winner with an allowed candidate is not a finding; an empty SNI is no name; ECH
  with an announced name is judged by that name; the reason identifiers are stable.
- `EncryptionAssessmentTests`: every row of the table above; an HTTP request is cleartext on any
  port and whatever the status says; a `plaintext` status alone is not cleartext and an `encrypted`
  one alone is not encrypted.
- `TLSVersionAssessmentTests`: every row of the table above; the threshold is the one given, for the
  version and for the offer; a listed weaker version outweighs an unrecognised one beside it; which
  versions are published; the reading without a threshold is the one judged, an unpublished
  version included, and a server's answer outweighs a QUIC reading.
- `FindingsClassifierTests`: flows that prove the same thing are one finding and a different version
  or source is another; flows seen in the clear are one finding; first-appearance order; each check
  places every flow exactly once; a session where nothing could be read — or recorded before the
  openings were — has neither findings nor satisfied flows; a policy needs a published
  minimum; connections to the same unlisted host are one finding and unnamed flows one per reason;
  the host check places every flow and none as not applicable; without an allowlist nothing is
  unexpected and nothing is expected; pinning is one finding per host and outcome, and a host
  with both gives both; without a trusted CA no pinning is reported; the pinning check places
  every flow and none as satisfied; the flows opened before consent are one finding; without a
  consent marker nothing is before and nothing is after; between two markers nothing is stated; a
  baseline has no consent to precede; the order of a flow's several findings; the kind
  identifiers are stable.
- `DomainPatternTests`: normalisation, the canonical text round-trips, every rejection, and the edges
  of a wildcard (own suffix, any depth, same trailing letters, a name that continues past the suffix).
- `AuditStoreTests`: a project and a session read back as written; the allowlist keeps its order; a
  duplicate pattern writes nothing; one open session, refused by the code and by the schema; ending
  rules; markers ordered by instant and refused outside an open session; the four tagging rules above,
  including a second store standing in for the extension; capture files derived, ignoring packets
  without capture; deleting a project keeps the flows; `clearAll` keeps the projects; a database
  stopped at `v5` migrates without losing anything; a project rewritten keeps its sessions and obeys
  the rules of creation; a deleted session takes its markers, untags its flows and stops the tagging;
  pruning leaves a session's flows alone until the session is deleted; the evidence files are those of
  every session and none from outside.
- `AuditStoreTests` also covers marking the open session: the marker lands in it and names its
  project; with no session (none at all, or one already ended) nothing is written and none is opened;
  a session ended by a second store — the app, seen from the control — is seen by the one that marks;
  and the rules of any marker still apply.
- `OpenSessionMarkingTests`: every option writes its own kind with the instant it was given; no open
  session, an unopenable database and a marker the store refuses are three reports and none of them
  is *placed*; the control's three states.
- `AuditMarkerIntentCopyTests`: the options are the session screen's fixed markers, name and symbol;
  the intent marks consent by default and never opens the app; the exact copy of the confirmation
  and of the two errors.
- `AuditViewModelTests`: coming back to the foreground shows a marker placed from outside, and a
  session deleted meanwhile is gone.
- `RetentionPlannerTests`, `CaptureHeadroomTests`, `StorageManagerTests`: evidence is skipped by both
  limits, the cause of an unmet size limit is told apart, and a cleanup that cannot read the evidence
  deletes nothing.
