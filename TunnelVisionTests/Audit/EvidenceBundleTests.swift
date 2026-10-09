import Foundation
import Shared
import XCTest

/// Tests de los documentos del paquete de evidencia: qué se niega a armar, qué dice cada
/// documento de la sesión y que lo que dice un fichero casa con lo que dice el otro.
final class EvidenceBundleTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private static let inspecting = InspectionConditions(inspectionEnabled: true, caTrusted: true)
    private static let notInspecting = InspectionConditions(inspectionEnabled: false, caTrusted: false)
    private static let exportedAt = Fixtures.start.addingTimeInterval(7_200.5)

    private func catalogue() throws -> RequirementCatalogue {
        try RequirementCatalogueLibrary.catalogue(identifier: RequirementCatalogueLibrary.defaultIdentifier)
    }

    private func makeBundle(
        _ flows: [StoredFlow],
        allowlist: [String] = [],
        session: AuditSession = Fixtures.session(inspection: notInspecting),
        markers: [SessionMarker] = []
    ) throws -> EvidenceBundle {
        try EvidenceBundle(
            project: try Fixtures.project(allowlist: allowlist),
            session: session,
            markers: markers,
            flows: flows,
            catalogue: try catalogue(),
            exportedWith: "1.1 (4)",
            exportedAt: Self.exportedAt
        )
    }

    private func json(_ file: EvidenceFile) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])
    }

    private func file(_ name: String, of bundle: EvidenceBundle) throws -> EvidenceFile {
        try XCTUnwrap(try bundle.documentFiles().first { $0.name == name })
    }

    // MARK: - Lo que no se arma

    func testASessionOfAnotherProjectIsRefused() throws {
        let project = AuditProject(
            id: 2, name: "Other", bundleIdentifier: nil, catalogueVersion: nil, allowlist: [],
            createdAt: Fixtures.start
        )
        XCTAssertThrowsError(try EvidenceBundle(
            project: project,
            session: Fixtures.session(inspection: Self.notInspecting),
            markers: [],
            flows: [],
            catalogue: try catalogue(),
            exportedWith: "1.1 (4)",
            exportedAt: Self.exportedAt
        )) { error in
            XCTAssertEqual(
                error as? EvidenceBundleError,
                .sessionOfAnotherProject(sessionProjectID: 1, projectID: 2)
            )
        }
    }

    func testAnOpenSessionIsRefused() throws {
        let closed = Fixtures.session(inspection: Self.notInspecting)
        let open = AuditSession(
            id: closed.id, projectID: closed.projectID, kind: closed.kind,
            environment: closed.environment, inspection: closed.inspection,
            startedAt: closed.startedAt, endedAt: nil, notes: ""
        )
        XCTAssertThrowsError(try makeBundle([], session: open)) { error in
            XCTAssertEqual(error as? EvidenceBundleError, .sessionStillOpen)
        }
    }

    func testTheSameFlowTwiceIsRefused() throws {
        XCTAssertThrowsError(try makeBundle([Fixtures.flow(id: 4), Fixtures.flow(id: 5), Fixtures.flow(id: 4)])) { error in
            XCTAssertEqual(error as? EvidenceBundleError, .duplicateFlow(id: 4))
        }
    }

    func testASessionWithNoFlowsStillGivesEveryDocument() throws {
        let bundle = try makeBundle([])

        XCTAssertEqual(bundle.flows.flowCount, 0)
        XCTAssertEqual(bundle.findings.findings, [])
        XCTAssertEqual(bundle.findings.requirements.count, 10)
        XCTAssertEqual(bundle.findings.checks.map(\.check), ["encryption", "tlsVersion", "host", "pinning", "consent"])
        XCTAssertEqual(
            try bundle.documentFiles().map(\.name),
            ["session.json", "flows.json", "flows.csv", "findings.json"]
        )
    }

    // MARK: - session.json

    func testTheSessionDocumentSaysWhatWasAuditedAndHow() throws {
        let project = AuditProject(
            id: 1,
            name: "Example",
            bundleIdentifier: "com.example.app",
            catalogueVersion: nil,
            allowlist: [
                AllowlistEntry(pattern: try DomainPattern(parsing: "*.Example.com."), note: "backend"),
                AllowlistEntry(pattern: try DomainPattern(parsing: "cdn.example.net"), note: nil),
            ],
            createdAt: Fixtures.start
        )
        let bundle = try EvidenceBundle(
            project: project,
            session: Fixtures.session(inspection: Self.inspecting),
            markers: [],
            flows: [],
            catalogue: try catalogue(),
            exportedWith: "1.1 (4)",
            exportedAt: Self.exportedAt
        )
        let document = bundle.session

        XCTAssertEqual(document.format, "tunnelvision.evidence.session")
        XCTAssertEqual(document.formatVersion, 1)
        XCTAssertEqual(document.exportedAt, Self.exportedAt)
        XCTAssertEqual(document.exportedWith, "1.1 (4)")
        XCTAssertEqual(document.project.bundleIdentifier, "com.example.app")
        XCTAssertEqual(document.project.allowlist.map(\.pattern), ["*.example.com", "cdn.example.net"])
        XCTAssertEqual(document.project.allowlist.map(\.note), ["backend", nil])
        XCTAssertEqual(document.session.kind, "audit")
        XCTAssertEqual(document.session.release?.version, "2.4.0")
        XCTAssertEqual(document.session.release?.build, "118")
        XCTAssertEqual(document.session.endedAt, Fixtures.start.addingTimeInterval(3_600))
        XCTAssertEqual(document.session.environment.toolVersion, "1.0 (1)")
        XCTAssertTrue(document.session.inspection.supportsPinningEvidence)
        XCTAssertTrue(document.contents.contains("Decrypted content is not part of this bundle"))
        XCTAssertTrue(document.attribution.contains("baseline"))
    }

    func testABaselineHasNoRelease() throws {
        let bundle = try makeBundle([], session: Fixtures.session(kind: .baseline, inspection: Self.notInspecting))

        XCTAssertEqual(bundle.session.session.kind, "baseline")
        XCTAssertNil(bundle.session.session.release)
        XCTAssertFalse(bundle.session.session.inspection.supportsPinningEvidence)

        let session = try XCTUnwrap(try json(file("session.json", of: bundle))["session"] as? [String: Any])
        XCTAssertNil(session["release"])
    }

    func testMarkersAreTheSessionsOwnInTheOrderTheyHappened() throws {
        let bundle = try makeBundle([], markers: [
            Fixtures.marker(id: 3, .custom("Onboarding done"), at: 90),
            Fixtures.marker(id: 9, at: 10, sessionID: 99),
            Fixtures.marker(id: 2, .loggedIn, at: 30),
            Fixtures.marker(id: 1, at: 30),
            Fixtures.marker(id: 4, .loggedOut, at: 120),
        ])

        XCTAssertEqual(bundle.session.markers.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(bundle.session.markers.map(\.kind), ["consentGiven", "loggedIn", "custom", "loggedOut"])
        XCTAssertEqual(bundle.session.markers.map(\.label), [nil, nil, "Onboarding done", nil])
    }

    func testAMarkerOfAnotherSessionDoesNotDateTheFlows() throws {
        // Con el marcador ajeno contado, el flujo 1 quedaría «antes del consentimiento».
        let bundle = try makeBundle(
            [Fixtures.flow(id: 1, streamOpening: .tlsHandshake)],
            markers: [Fixtures.marker(id: 9, at: 600, sessionID: 99)]
        )

        XCTAssertFalse(bundle.findings.findings.contains { $0.kind == "activityBeforeConsent" })
        let consent = try XCTUnwrap(bundle.findings.checks.first { $0.check == "consent" })
        XCTAssertEqual(consent.unassessed.map(\.reason), ["noConsentMarker"])
    }

    // MARK: - Los hallazgos y quién los cita

    func testFindingsAreNumberedInOrderAndEachFlowCitesItsOwn() throws {
        let bundle = try makeBundle(
            [
                Fixtures.flow(id: 1, sni: "api.example.com", streamOpening: .tlsHandshake),
                Fixtures.flow(id: 2, remotePort: 80, tlsStatus: .plaintext, sni: nil, streamOpening: .httpRequest),
                Fixtures.flow(id: 3, sni: "tracker.example.net", serverTLS: Fixtures.negotiated(.tls10)),
                Fixtures.flow(id: 4, sni: "tracker.example.net", streamOpening: .tlsHandshake),
            ],
            allowlist: ["api.example.com"]
        )
        let findings = bundle.findings.findings

        XCTAssertEqual(findings.map(\.id), ["F1", "F2", "F3", "F4"])
        XCTAssertEqual(findings.map(\.kind), ["cleartextTraffic", "unnamedFlow", "weakTLSVersion", "hostNotInAllowlist"])
        XCTAssertEqual(findings.map(\.flowIDs), [[2], [2], [3], [3, 4]])
        XCTAssertEqual(bundle.flows.flows.map(\.findingIDs), [[], ["F1", "F2"], ["F3", "F4"], ["F4"]])
        XCTAssertEqual(bundle.assessment.findings.findings.count, 4)
    }

    func testAFindingCarriesWhatItStatesInItsOwnFields() throws {
        let bundle = try makeBundle(
            [
                Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext, sni: nil, streamOpening: .httpRequest),
                Fixtures.flow(
                    id: 2,
                    sni: "Tracker.Example.net.",
                    serverTLS: Fixtures.negotiated(.tls11, fromHelloRetryRequest: true)
                ),
            ],
            allowlist: ["api.example.com"]
        )
        let byKind = Dictionary(uniqueKeysWithValues: bundle.findings.findings.map { ($0.kind, $0) })

        let cleartext = try XCTUnwrap(byKind["cleartextTraffic"])
        XCTAssertEqual(cleartext.cleartextProtocol, "http")
        XCTAssertEqual(cleartext.statement, "An HTTP request was observed in the clear.")
        XCTAssertNil(cleartext.host)

        let unnamed = try XCTUnwrap(byKind["unnamedFlow"])
        XCTAssertEqual(unnamed.unnamedReason, "noClientHelloRead")

        let weak = try XCTUnwrap(byKind["weakTLSVersion"])
        XCTAssertEqual(weak.tlsVersion?.version.name, "TLS 1.1")
        XCTAssertEqual(weak.tlsVersion?.version.wireValue, 0x0302)
        XCTAssertEqual(weak.tlsVersion?.basis, "serverHello")
        XCTAssertEqual(weak.tlsVersion?.fromHelloRetryRequest, true)
        XCTAssertEqual(weak.statement, "A connection negotiated a TLS version below TLS 1.2.")

        let host = try XCTUnwrap(byKind["hostNotInAllowlist"])
        XCTAssertEqual(host.host, "tracker.example.net")
        XCTAssertNil(host.tlsVersion)
    }

    func testAWeakUpstreamReadingSaysWhoseConnectionItWas() throws {
        let bundle = try makeBundle([
            Fixtures.flow(id: 1, tlsStatus: .inspected, serverTLS: Fixtures.negotiated(.tls10, source: .upstreamConnection)),
        ])
        let weak = try XCTUnwrap(bundle.findings.findings.first { $0.kind == "weakTLSVersion" })

        XCTAssertEqual(weak.tlsVersion?.basis, "upstreamConnection")
        XCTAssertNil(weak.tlsVersion?.fromHelloRetryRequest)
        XCTAssertTrue(weak.statement.contains("with the tunnel's own connection"))
    }

    // MARK: - Los requisitos

    func testARequirementCitesTheFindingsBehindItsVerdict() throws {
        let bundle = try makeBundle(
            [
                Fixtures.flow(id: 1, tlsStatus: .inspected, sni: "api.example.com", streamOpening: .tlsHandshake),
                Fixtures.flow(id: 2, tlsStatus: .notInspectable, sni: "bank.example.com", streamOpening: .tlsHandshake),
                Fixtures.flow(id: 3, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest),
            ],
            session: Fixtures.session(inspection: Self.inspecting)
        )
        let requirements = Dictionary(uniqueKeysWithValues: bundle.findings.requirements.map { ($0.id, $0) })
        let ids = Dictionary(uniqueKeysWithValues: bundle.findings.findings.map { ($0.kind, $0.id) })

        let encryption = try XCTUnwrap(requirements["O.Ntwk_1"])
        XCTAssertEqual(encryption.verdict, "contradicted")
        XCTAssertNil(encryption.notAssessedReason)
        XCTAssertEqual(encryption.contraryFindingIDs, [try XCTUnwrap(ids["cleartextTraffic"])])
        XCTAssertEqual(encryption.check, "encryption")
        XCTAssertEqual(encryption.rule, "contraryFindings")
        XCTAssertEqual(encryption.testDepth, "EXAMINE")
        XCTAssertFalse(try XCTUnwrap(encryption.toolCoverage).isEmpty)

        // Un rechazo no deja de haberlo sido porque otro host aceptara: van los dos.
        let pinning = try XCTUnwrap(requirements["O.Ntwk_4"])
        XCTAssertEqual(pinning.verdict, "contradicted")
        XCTAssertEqual(pinning.contraryFindingIDs, [try XCTUnwrap(ids["pinningAbsent"])])
        XCTAssertEqual(pinning.supportingFindingIDs, [try XCTUnwrap(ids["pinningObserved"])])
        XCTAssertEqual(pinning.rule, "contraryAndSupportingFindings")

        let version = try XCTUnwrap(requirements["O.Ntwk_2"])
        XCTAssertEqual(version.verdict, "notAssessed")
        XCTAssertEqual(version.notAssessedReason, "nothingObserved")

        let outside = try XCTUnwrap(requirements["O.Ntwk_3"])
        XCTAssertEqual(outside.verdict, "notAssessed")
        XCTAssertEqual(outside.notAssessedReason, "outsideToolScope")
        XCTAssertEqual(outside.verdictStatement, "Not assessed by this tool.")
        XCTAssertEqual(outside.rule, "outsideToolScope")
        XCTAssertNil(outside.check)
        XCTAssertNil(outside.toolCoverage)
        XCTAssertEqual(outside.aspect.number, 9)
    }

    func testEveryRequirementThatCanGetAVerdictPrintsItsCoverage() throws {
        let bundle = try makeBundle([Fixtures.flow(id: 1, streamOpening: .tlsHandshake)])

        for requirement in bundle.findings.requirements where requirement.check != nil {
            XCTAssertFalse((requirement.toolCoverage ?? "").isEmpty, requirement.id)
        }
        let observed = try XCTUnwrap(bundle.findings.requirements.first { $0.id == "O.Ntwk_1" })
        XCTAssertEqual(observed.verdict, "observedWithoutContradiction")
    }

    func testTheCatalogueIsCitedWithItsDocuments() throws {
        let cited = try makeBundle([]).findings.catalogue

        XCTAssertEqual(cited.identifier, "tr-03161-1_3.0")
        XCTAssertEqual(cited.source.document, "BSI TR-03161-1")
        XCTAssertEqual(cited.source.version, "3.0")
        XCTAssertEqual(cited.source.date, "2024-03-25")
        XCTAssertEqual(cited.source.sha256.count, 64)
        XCTAssertEqual(cited.minimumTLSVersion.name, "TLS 1.2")
        XCTAssertEqual(cited.tlsSource.document, "BSI TR-02102-2")
    }

    // MARK: - Las comprobaciones

    func testACheckSaysWhyItCouldNotLookWithTheDetailsOfEachReason() throws {
        let ceiling = Fixtures.offer(.upTo(.tls12))
        let bundle = try makeBundle(
            [
                Fixtures.flow(id: 1, serverTLS: .refused(alert: 70)),
                Fixtures.flow(
                    id: 2,
                    tlsStatus: .inspected,
                    serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection),
                    clientTLS: ceiling
                ),
                Fixtures.flow(id: 3, proto: .udp, sni: nil, quic: QUICVersionReading(version: .v1, source: .client)),
                Fixtures.flow(id: 4, serverTLS: Fixtures.negotiated(TLSProtocolVersion(rawValue: 0x7F1C))),
                Fixtures.flow(
                    id: 5,
                    sni: nil,
                    resolvedName: ResolvedFlowName(name: "api.example.com", otherNames: ["ads.example.net"]),
                    streamOpening: .tlsHandshake
                ),
                Fixtures.flow(id: 6, proto: .icmp, tlsStatus: .plaintext, sni: nil),
                Fixtures.flow(id: 7),
            ],
            allowlist: ["api.example.com"]
        )
        let checks = Dictionary(uniqueKeysWithValues: bundle.findings.checks.map { ($0.check, $0) })

        let version = try XCTUnwrap(checks["tlsVersion"])
        XCTAssertEqual(
            version.unassessed.map(\.reason),
            ["serverRefused", "appNegotiationNotObserved", "quicVersionOnlyProposed", "unrecognisedVersion", "serverAnswerNotRead"]
        )
        XCTAssertEqual(version.unassessed[0].alert, 70)
        XCTAssertEqual(version.unassessed[0].flowIDs, [1])
        XCTAssertEqual(version.unassessed[1].upstreamVersion?.name, "TLS 1.3")
        XCTAssertEqual(version.unassessed[1].clientOffer, "ceilingOnly")
        XCTAssertEqual(version.unassessed[1].clientOfferCeiling?.name, "TLS 1.2")
        XCTAssertEqual(version.unassessed[2].quicVersion?.hex, "0x00000001")
        XCTAssertEqual(version.unassessed[3].tlsVersion?.version.wireValue, 0x7F1C)
        XCTAssertNil(version.unassessed[3].tlsVersion?.version.name)
        XCTAssertEqual(version.notApplicableFlowIDs, [6])

        let host = try XCTUnwrap(checks["host"])
        XCTAssertEqual(host.unassessed.map(\.reason), ["candidatesDisagree"])
        XCTAssertEqual(host.unassessed.first?.attributedNameAllowed, true)
        XCTAssertEqual(host.unassessed.first?.flowIDs, [5])

        let pinning = try XCTUnwrap(checks["pinning"])
        XCTAssertEqual(pinning.satisfiedFlowIDs, [])
        XCTAssertEqual(pinning.unassessed.map(\.reason), ["inspectionOff"])

        let encryption = try XCTUnwrap(checks["encryption"])
        XCTAssertEqual(encryption.notApplicableFlowIDs, [6])
        XCTAssertTrue(encryption.unassessed.contains { $0.reason == "openingNotRead" })
    }

    func testEveryFlowLandsOnceInEachCheck() throws {
        let flows = [
            Fixtures.flow(id: 1, streamOpening: .tlsHandshake),
            Fixtures.flow(id: 2, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest),
            Fixtures.flow(id: 3, proto: .udp, sni: nil, quic: QUICVersionReading(version: .v1, source: .server)),
            Fixtures.flow(id: 4, proto: .icmp, tlsStatus: .plaintext, sni: nil),
        ]
        let bundle = try makeBundle(flows, allowlist: ["api.example.com"])

        for check in bundle.findings.checks {
            let kinds = Set(FindingKind.allCases.filter { $0.check.rawValue == check.check }.map(\.rawValue))
            let inFindings = Set(bundle.findings.findings.filter { kinds.contains($0.kind) }.flatMap(\.flowIDs))
            let elsewhere = check.satisfiedFlowIDs + check.unassessed.flatMap(\.flowIDs) + check.notApplicableFlowIDs
            XCTAssertEqual(Set(elsewhere).count, elsewhere.count, check.check)
            XCTAssertTrue(inFindings.isDisjoint(with: elsewhere), check.check)
            XCTAssertEqual(inFindings.union(elsewhere), Set(flows.map(\.id)), check.check)
        }
    }

    // MARK: - flows.json

    func testAFlowIsWrittenWithEveryReadingAndItsSource() throws {
        let flow = Fixtures.flow(
            id: 1,
            tlsStatus: .inspected,
            sni: "api.example.com",
            serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection),
            clientTLS: Fixtures.offer(.listed([.tls13, .tls12]), encryptedClientHello: true),
            streamOpening: .tlsHandshake
        )
        let written = try XCTUnwrap(try makeBundle([flow]).flows.flows.first)

        XCTAssertEqual(written.proto, "tcp")
        XCTAssertEqual(written.peers.map(\.address), ["10.7.0.2", "203.0.113.9"])
        XCTAssertEqual(written.peers.map(\.port), [50_000, 443])
        XCTAssertEqual(written.tlsStatus, "inspected")
        XCTAssertEqual(written.name?.text, "api.example.com")
        XCTAssertEqual(written.name?.origin, "sni")
        XCTAssertEqual(written.streamOpening, "tlsHandshake")
        XCTAssertEqual(written.bytesOut, 900)
        XCTAssertEqual(written.bytesIn, 4_200)
        XCTAssertEqual(written.durationSeconds, 1)

        XCTAssertEqual(written.serverTLS?.answer, "negotiated")
        XCTAssertEqual(written.serverTLS?.version?.name, "TLS 1.3")
        XCTAssertEqual(written.serverTLS?.cipherSuite?.hex, "0xC02F")
        XCTAssertEqual(written.serverTLS?.cipherSuite?.wireValue, 0xC02F)
        XCTAssertEqual(written.serverTLS?.source, "upstreamConnection")
        XCTAssertNil(written.serverTLS?.alert)

        XCTAssertEqual(written.clientTLS?.versionsForm, "listed")
        XCTAssertEqual(written.clientTLS?.versions.map(\.name), ["TLS 1.3", "TLS 1.2"])
        XCTAssertEqual(written.clientTLS?.applicationProtocols, ["h2"])
        XCTAssertEqual(written.clientTLS?.hasEncryptedClientHello, true)

        XCTAssertEqual(written.serverCertificate.visibility, "replacedByInspection")
        XCTAssertNil(written.serverCertificate.chain)
    }

    func testACeilingIsNotWrittenAsAListAndARefusalKeepsItsAlert() throws {
        let flow = Fixtures.flow(id: 1, serverTLS: .refused(alert: 40), clientTLS: Fixtures.offer(.upTo(.tls12)))
        let written = try XCTUnwrap(try makeBundle([flow]).flows.flows.first)

        XCTAssertEqual(written.clientTLS?.versionsForm, "upTo")
        XCTAssertEqual(written.clientTLS?.versions.map(\.name), ["TLS 1.2"])
        XCTAssertEqual(written.serverTLS?.answer, "refused")
        XCTAssertEqual(written.serverTLS?.alert, 40)
        XCTAssertNil(written.serverTLS?.version)
        XCTAssertNil(written.serverTLS?.source)
        XCTAssertEqual(written.serverCertificate.visibility, "noNegotiation")
    }

    func testANameFromDNSIsWrittenApartFromAnAnnouncedOne() throws {
        let flow = Fixtures.flow(
            id: 1,
            proto: .udp,
            tlsStatus: .encrypted,
            sni: nil,
            resolvedName: ResolvedFlowName(name: "cdn.example.net", otherNames: ["img.example.net"]),
            quic: QUICVersionReading(version: .v2, source: .server)
        )
        let written = try XCTUnwrap(try makeBundle([flow]).flows.flows.first)

        XCTAssertNil(written.sni)
        XCTAssertEqual(written.dnsName, "cdn.example.net")
        XCTAssertEqual(written.dnsOtherNames, ["img.example.net"])
        XCTAssertEqual(written.name?.origin, "dns")
        XCTAssertEqual(written.proto, "udp")
        XCTAssertEqual(written.quic?.version.hex, "0x6B3343CF")
        XCTAssertEqual(written.quic?.source, "server")
        XCTAssertNil(written.streamOpening)
        XCTAssertEqual(written.serverCertificate.visibility, "notRead")
    }

    func testThePresentedCertificateChainIsWrittenAndSaysIfItIsWhole() throws {
        let base = Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12))
        let notAfter = Fixtures.start.addingTimeInterval(86_400)
        func flow(id: Int64, _ reading: ServerCertificateReading?, tls: ServerTLSAnswer?) -> StoredFlow {
            StoredFlow(
                id: id, key: base.key, firstSeen: base.firstSeen, lastSeen: base.lastSeen,
                bytesOut: 1, bytesIn: 1, packetCount: 2, tlsStatus: .encrypted, sni: "api.example.com",
                resolvedName: nil, serverTLS: tls, serverCertificates: reading, clientTLS: nil,
                quic: nil, streamOpening: .tlsHandshake
            )
        }
        let chain = ServerCertificateChain(
            certificates: [ServerCertificate(
                subject: CertificateName(text: "CN=api.example.com", isTruncated: false),
                issuer: CertificateName(text: "CN=Example CA,O=Example", isTruncated: true),
                notAfter: notAfter
            )],
            isComplete: false
        )
        let written = try makeBundle([
            flow(id: 1, .chain(chain), tls: Fixtures.negotiated(.tls12)),
            flow(id: 2, .notSent(.resumedSession), tls: Fixtures.negotiated(.tls12)),
            flow(id: 3, nil, tls: Fixtures.negotiated(.tls13)),
        ]).flows.flows.map(\.serverCertificate)

        XCTAssertEqual(written[0].visibility, "presented")
        XCTAssertEqual(written[0].chain?.map(\.subject), ["CN=api.example.com"])
        XCTAssertEqual(written[0].chain?.first?.issuerIsTruncated, true)
        XCTAssertEqual(written[0].chain?.first?.notAfter, notAfter)
        XCTAssertEqual(written[0].chainIsComplete, false)
        XCTAssertEqual(written[1].visibility, "notSent")
        XCTAssertEqual(written[1].absence, "resumedSession")
        XCTAssertNil(written[1].chain)
        XCTAssertEqual(written[2].visibility, "encryptedInHandshake")
    }

    // MARK: - Los bytes

    func testTheEncodedDocumentsAreTheSameBytesEveryTime() throws {
        let flows = [
            Fixtures.flow(id: 1, streamOpening: .tlsHandshake),
            Fixtures.flow(id: 2, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest),
        ]
        XCTAssertEqual(try makeBundle(flows).documentFiles(), try makeBundle(flows).documentFiles())
    }

    func testTheEncodedDocumentsAreReadableOutsideTheApp() throws {
        let bundle = try makeBundle([Fixtures.flow(id: 1, streamOpening: .tlsHandshake)])

        let session = try json(file("session.json", of: bundle))
        XCTAssertEqual(session["format"] as? String, "tunnelvision.evidence.session")
        XCTAssertEqual(session["formatVersion"] as? Int, 1)
        // En UTC y con fracción de segundo: el instante no depende de la región de quien lo lee.
        XCTAssertEqual(session["exportedAt"] as? String, "2026-09-21T16:13:20.500Z")

        let flows = try json(file("flows.json", of: bundle))
        XCTAssertEqual(flows["format"] as? String, "tunnelvision.evidence.flows")
        XCTAssertEqual(flows["flowCount"] as? Int, 1)
        let flow = try XCTUnwrap((flows["flows"] as? [[String: Any]])?.first)
        XCTAssertEqual(flow["protocol"] as? String, "tcp")
        XCTAssertNil(flow["proto"])
        // Una lectura que no se hizo es una clave ausente, no un `null`.
        XCTAssertNil(flow["serverTLS"])
        XCTAssertNotNil(flow["serverCertificate"])

        let findings = try json(file("findings.json", of: bundle))
        XCTAssertEqual(findings["format"] as? String, "tunnelvision.evidence.findings")
        XCTAssertEqual(findings["sessionID"] as? Int, 7)
        XCTAssertEqual((findings["requirements"] as? [[String: Any]])?.count, 10)
        XCTAssertNotNil(findings["verdicts"] as? String)
    }

    // MARK: - La redacción

    private static let everyEvidence: [FindingEvidence] = [
        .weakTLSVersion(TLSVersionObservation(version: .tls10, basis: .serverHello(fromHelloRetryRequest: false))),
        .weakTLSVersion(TLSVersionObservation(version: .tls10, basis: .upstreamConnection)),
        .weakTLSVersion(TLSVersionObservation(version: .tls13, basis: .quic(.v1))),
        .cleartextTraffic(.http),
        .hostNotInAllowlist(host: "tracker.example.net"),
        .unnamedFlow(.serverNameNotAnnounced),
        .unnamedFlow(.encryptedClientHello),
        .unnamedFlow(.noClientHelloRead),
        .pinningAbsent(host: "api.example.com"),
        .pinningObserved(host: "bank.example.com"),
        .activityBeforeConsent,
    ]

    private static let everyVerdict: [RequirementVerdict] = [
        .contradicted,
        .observedWithoutContradiction,
        .notAssessed(.outsideToolScope),
        .notAssessed(.nothingObserved),
    ]

    func testNoWordingEverSaysARequirementIsPassed() throws {
        let policy = try XCTUnwrap(FindingsPolicy(minimumTLSVersion: .tls12))
        let wordings = Self.everyEvidence.map { EvidenceWording.statement(of: $0, policy: policy) }
            + Self.everyVerdict.map(EvidenceWording.statement(of:))
            + [
                EvidenceWording.verdictsNote,
                EvidenceSessionDocument.contentsNote,
                EvidenceSessionDocument.attributionNote,
                EvidenceFlowsDocument.contentsNote,
            ]

        for wording in wordings {
            let words = wording.lowercased().split { !$0.isLetter }.map(String.init)
            for forbidden in ["pass", "passed", "passes", "compliant", "fulfilled", "satisfied"] {
                XCTAssertFalse(words.contains(forbidden), wording)
            }
        }
        XCTAssertEqual(Set(wordings).count, wordings.count)
    }

    func testPinningIsWordedAboutTheHostAndNeverAboutTheApp() throws {
        let policy = try XCTUnwrap(FindingsPolicy(minimumTLSVersion: .tls12))
        let observed = EvidenceWording.statement(of: .pinningObserved(host: "bank.example.com"), policy: policy)

        XCTAssertTrue(observed.hasPrefix("A connection to this host refused the local CA's certificate."))
        XCTAssertTrue(observed.contains("may predate this session"))
        XCTAssertFalse(observed.lowercased().contains("the app pins"))
        XCTAssertFalse(observed.contains("bank.example.com"))
    }

    func testANotAssessedVerdictIsWordedAsNotAssessedByThisTool() {
        XCTAssertEqual(EvidenceWording.statement(of: .notAssessed(.outsideToolScope)), "Not assessed by this tool.")
        XCTAssertTrue(
            EvidenceWording.statement(of: .notAssessed(.nothingObserved)).hasPrefix("Not assessed by this tool")
        )
        XCTAssertTrue(EvidenceWording.verdictsNote.contains("not a test result"))
    }

    func testTheWeakVersionStatementCitesTheCataloguesOwnMinimum() throws {
        let policy = try XCTUnwrap(FindingsPolicy(minimumTLSVersion: .tls13))
        let statement = EvidenceWording.statement(
            of: .weakTLSVersion(TLSVersionObservation(version: .tls12, basis: .serverHello(fromHelloRetryRequest: false))),
            policy: policy
        )
        XCTAssertEqual(statement, "A connection negotiated a TLS version below TLS 1.3.")
    }
}
