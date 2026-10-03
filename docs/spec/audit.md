# Spec — Audit model (`Shared/Audit`, schema `v6`)

The data model of the TR-03161 network evidence workflow: what is audited, each recording of it, and
the instants marked inside a recording. Scope and attribution method:
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

## Tests

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
- `RetentionPlannerTests`, `CaptureHeadroomTests`, `StorageManagerTests`: evidence is skipped by both
  limits, the cause of an unmet size limit is told apart, and a cleanup that cannot read the evidence
  deletes nothing.
