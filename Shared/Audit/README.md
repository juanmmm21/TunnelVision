# Shared/Audit

The value types of the TR-03161 network evidence workflow: `AuditProject` (what is audited, with its
domain allowlist of `DomainPattern`s), `AuditSession` (one named recording of it — a `baseline` or an
`audit` of a given `AppRelease`, with the device and the inspection conditions it was made under) and
`SessionMarker` (an instant marked inside a session: consent given, logged in, logged out, custom).
`AuditRecording` and `OpenSessionMarkerOutcome` are what marking *the open session* returns, for
whoever marks without knowing which one it is. All `Sendable`; Foundation-only.

They live in `Shared` because three processes meet them: the app creates and reads them, the
tunnel extension's writes are tagged with the open session, and the controls extension places
markers in it. Their storage is the audit half of `FlowStore`
(`../Persistence/FlowStore+Audit.swift`, schema `v6`).

`FindingsClassifier` reads the flows of a session and returns what they prove: a `Finding` is a
statement (`FindingEvidence`) with the flows behind it, and each check also returns its
`CheckCoverage` — what it found in order, what it could not look at and why — so that "no findings"
is never mistaken for "nothing wrong". Thresholds arrive in a `FindingsPolicy`; none is written here.
`TLSVersionAssessment` is the per-flow rule behind `weakTLSVersion`, and `EncryptionAssessment`
the one behind `cleartextTraffic` — which only ever comes from an HTTP request that was seen, never
from a port number. `HostAssessment` is the one behind `hostNotInAllowlist` and `unnamedFlow`: it
judges a flow's name against the project's allowlist, and a name deduced from DNS only counts when
every name that shared its address falls on the same side. `PinningAssessment` is the one behind
`pinningAbsent` and `pinningObserved`: it reads the outcome the relay recorded for an inspection
attempt — it bypasses nothing — and only in a session recorded with inspection on and the CA
trusted. `ConsentAssessment` is the one behind `activityBeforeConsent`: a flow's first packet
against the session's `consentGiven` markers (`ConsentInterval`), with no marker meaning *not
assessed* rather than nothing found.

`RequirementCatalogue` is one version of a requirements document read from a JSON resource
(`Requirements/`, bundled with the framework): each requirement's identifier and title as the
document gives them, the finding kinds that bear on it and one of three closed rules. A miswritten
catalogue is refused when it is loaded. `SessionAssessment` classifies a session with the
catalogue's thresholds and gives a `RequirementVerdict` per requirement — contradicted, observed
without contradiction, or not assessed. There is no verdict that says *passed*: that is the
assessor's to give. `RequirementCatalogueLibrary` finds the catalogue of a project.

`Evidence/` holds the documents a closed session is exported as. `EvidenceBundle` classifies the
session itself and gives `session.json`, `flows.json` (with `flows.csv`, its flattened view) and
`findings.json` as values that encode to the same bytes every time; `EvidenceManifest` lists the
SHA-256 of each file. Every sentence the bundle writes is in `EvidenceWording`. None of those
touches the disk. `EvidenceCaptureWriter` is the part that does: it slices the device's capture
files to the packets of the session's flows and writes `capture.pcapng`, each packet commented
with its flow and that flow's findings, hashing as it writes; `EvidenceCaptureDocument`
(`capture.json`) counts, per flow and per reason, the packets that are not in it. The folder and
the archive are written by the app's `EvidenceExporter` (`TunnelVision/Services`).
`EvidenceReport` is what the bundle's report says, as headings, notes, fact lists and tables read
off those documents, with nothing drawn — composing it into pages and drawing `report.pdf` is the
app's (`EvidenceReportLayout`, `EvidenceReportPDF`): what the bundle already words it quotes, and
its lists are bounded by `EvidenceReportLimits` and say what they left out. `EvidenceCaptureStanding` is
the one reading of `capture.json` — every packet there, none recorded, or some missing — that the
report and the app's export sheet share.

An *audit* session is not the *capture* session of `FlowStore`: the latter is the instant the store was
opened and only keeps a recycled 5-tuple from merging two connections.

**Spec:** [`../../docs/spec/audit.md`](../../docs/spec/audit.md) ·
**Decision:** [`../../docs/decisions/0008-tr03161-audit-workflow-scope.md`](../../docs/decisions/0008-tr03161-audit-workflow-scope.md)
