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
    public func deleteAuditProject(id: Int64) throws

    public func startAuditSession(_ draft: AuditSessionDraft, at date: Date) throws -> AuditSession
    public func endAuditSession(id: Int64, at date: Date) throws -> AuditSession
    public func openAuditSession() throws -> AuditSession?
    public func auditSession(id: Int64) throws -> AuditSession?
    public func auditSessions(forProject projectID: Int64) throws -> [AuditSession]   // newest first

    public func addMarker(_ kind: SessionMarkerKind, toSession id: Int64, at date: Date) throws -> SessionMarker
    public func markers(forSession id: Int64) throws -> [SessionMarker]        // as they happened

    public func flows(inAuditSession id: Int64, limit: Int) throws -> [StoredFlow]    // oldest first
    public func captureFileSequences(inAuditSession id: Int64) throws -> Set<UInt32>
}
```

- A marker needs an **open** session. On a closed one it is an error, not a late correction: a marker
  placed after looking at the traffic is no longer an observation.
- `flows(inAuditSession:)` is ordered by `first_seen` **ascending**, the opposite of `recentFlows`.
  The Timeline is read from now backwards; evidence is read as it happened.
- Domain-rule violations throw `AuditStoreError`; an unreadable row throws `StoreError.corruptRow`.

## Tests

- `DomainPatternTests`: normalisation, the canonical text round-trips, every rejection, and the edges
  of a wildcard (own suffix, any depth, same trailing letters, a name that continues past the suffix).
- `AuditStoreTests`: a project and a session read back as written; the allowlist keeps its order; a
  duplicate pattern writes nothing; one open session, refused by the code and by the schema; ending
  rules; markers ordered by instant and refused outside an open session; the four tagging rules above,
  including a second store standing in for the extension; capture files derived, ignoring packets
  without capture; deleting a project keeps the flows; `clearAll` keeps the projects; a database
  stopped at `v5` migrates without losing anything.
