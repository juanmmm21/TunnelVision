import Foundation
import Shared
import XCTest

/// Tests del contenido del informe del paquete de evidencia: qué secciones lleva, qué dice en
/// cada una, que lo que imprime es lo que dicen los ficheros de al lado, y que ninguna frase
/// afirma más de lo que se observó.
final class EvidenceReportTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private static let inspecting = InspectionConditions(inspectionEnabled: true, caTrusted: true)
    private static let notInspecting = InspectionConditions(inspectionEnabled: false, caTrusted: false)
    private static let exportedAt = Fixtures.start.addingTimeInterval(7_200.5)

    private func limits(flowIDs: Int = 10, rows: Int = 10) throws -> EvidenceReportLimits {
        try XCTUnwrap(EvidenceReportLimits(flowIDsPerFinding: flowIDs, tlsReadingRows: rows))
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
            catalogue: try RequirementCatalogueLibrary.catalogue(
                identifier: RequirementCatalogueLibrary.defaultIdentifier
            ),
            exportedWith: "1.1 (4)",
            exportedAt: Self.exportedAt
        )
    }

    /// Un `capture.json` con todos los paquetes en un solo flujo: el informe solo lee los totales.
    private func capture(
        sessionID: Int64 = Fixtures.sessionID,
        written: Int = 0,
        lost: [EvidencePacketLoss: Int] = [:],
        beforeStart: Int = 0,
        afterEnd: Int = 0
    ) -> EvidenceCaptureDocument {
        EvidenceCaptureDocument(
            sessionID: sessionID,
            snaplen: 262_144,
            flows: [.init(id: 1, packets: EvidencePacketTally(written: written, lost: lost))],
            sourceFiles: [],
            writtenOutsideSession: .init(beforeStart: beforeStart, afterEnd: afterEnd)
        )
    }

    private func report(
        _ bundle: EvidenceBundle,
        capture: EvidenceCaptureDocument? = nil,
        limits: EvidenceReportLimits? = nil
    ) throws -> EvidenceReport {
        try EvidenceReport(
            bundle: bundle,
            capture: capture ?? self.capture(written: 10),
            limits: try limits ?? self.limits()
        )
    }

    private func section(_ kind: EvidenceReportSectionKind, of report: EvidenceReport) throws -> EvidenceReportSection {
        try XCTUnwrap(report.sections.first { $0.kind == kind })
    }

    private func facts(_ blocks: [EvidenceReportBlock]) -> [EvidenceReportFact] {
        blocks.flatMap { block -> [EvidenceReportFact] in
            if case .facts(let facts) = block { return facts }
            return []
        }
    }

    private func tables(_ blocks: [EvidenceReportBlock]) -> [EvidenceReportTable] {
        blocks.compactMap { block in
            if case .table(let table) = block { return table }
            return nil
        }
    }

    private func value(_ label: String, in blocks: [EvidenceReportBlock]) -> String? {
        facts(blocks).first { $0.label == label }?.value
    }

    /// Los bloques de un apartado: desde su encabezado hasta el siguiente.
    private func blocks(under heading: String, in blocks: [EvidenceReportBlock]) throws -> [EvidenceReportBlock] {
        let start = try XCTUnwrap(blocks.firstIndex(of: .heading(heading)), heading)
        let rest = blocks[(start + 1)...]
        let end = rest.firstIndex { block in
            if case .heading = block { return true }
            return false
        } ?? rest.endIndex
        return Array(rest[..<end])
    }

    /// Todo el texto que el informe imprimiría.
    private func everyText(of report: EvidenceReport) -> [String] {
        var texts = [report.title, report.subtitle]
        for section in report.sections {
            texts.append(section.title)
            for block in section.blocks {
                switch block {
                case .heading(let text), .paragraph(let text), .note(let text):
                    texts.append(text)
                case .facts(let facts):
                    texts += facts.flatMap { [$0.label, $0.value] }
                case .table(let table):
                    texts += table.columns + table.rows.flatMap { $0 }
                }
            }
        }
        return texts
    }

    /// Una sesión con un poco de todo: cada comprobación con hallazgos, flujos sin incidencia,
    /// motivos por los que no pudo mirar y flujos a los que no aplica.
    private func variedBundle() throws -> EvidenceBundle {
        try makeBundle(
            [
                Fixtures.flow(id: 1, tlsStatus: .inspected, serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection), clientTLS: Fixtures.offer(.upTo(.tls12)), streamOpening: .tlsHandshake),
                Fixtures.flow(id: 2, tlsStatus: .notInspectable, sni: "bank.example.com", serverTLS: Fixtures.negotiated(.tls13), streamOpening: .tlsHandshake),
                Fixtures.flow(id: 3, remotePort: 80, tlsStatus: .plaintext, sni: nil, streamOpening: .httpRequest),
                Fixtures.flow(id: 4, sni: "tracker.example.net", serverTLS: Fixtures.negotiated(.tls10)),
                Fixtures.flow(id: 5, sni: "tracker.example.net", serverTLS: Fixtures.negotiated(.tls13)),
                Fixtures.flow(id: 6, proto: .udp, sni: nil, quic: QUICVersionReading(version: .v1, source: .client)),
                Fixtures.flow(id: 7, serverTLS: .refused(alert: 70)),
                Fixtures.flow(id: 8, proto: .icmp, tlsStatus: .plaintext, sni: nil),
                Fixtures.flow(
                    id: 9,
                    sni: nil,
                    resolvedName: ResolvedFlowName(name: "api.example.com", otherNames: ["ads.example.net"]),
                    streamOpening: .tlsHandshake
                ),
            ],
            allowlist: ["api.example.com", "bank.example.com"],
            session: Fixtures.session(inspection: Self.inspecting),
            markers: [Fixtures.marker(id: 1, at: 4.5), Fixtures.marker(id: 2, .custom("Opened the diary"), at: 6)]
        )
    }

    // MARK: - Qué no se arma

    func testACaptureDocumentOfAnotherSessionIsRefused() throws {
        let bundle = try makeBundle([])

        XCTAssertThrowsError(try report(bundle, capture: capture(sessionID: 8))) { error in
            XCTAssertEqual(
                error as? EvidenceReportError,
                .captureOfAnotherSession(captureSessionID: 8, sessionID: Fixtures.sessionID)
            )
        }
    }

    func testLimitsThatWouldPrintNothingAreRefused() {
        XCTAssertNil(EvidenceReportLimits(flowIDsPerFinding: 0, tlsReadingRows: 10))
        XCTAssertNil(EvidenceReportLimits(flowIDsPerFinding: 10, tlsReadingRows: 0))
        XCTAssertNotNil(EvidenceReportLimits(flowIDsPerFinding: 1, tlsReadingRows: 1))
    }

    // MARK: - La forma

    func testEverySectionIsThereInOrderEvenForASessionWithNoFlows() throws {
        let report = try report(try makeBundle([]), capture: capture())

        XCTAssertEqual(report.title, "Network evidence report")
        XCTAssertEqual(
            report.sections.map(\.kind),
            [.session, .method, .catalogue, .requirements, .findings, .checks, .tlsReadings, .capture]
        )
        for section in report.sections {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.blocks.isEmpty, section.kind.rawValue)
        }
    }

    func testEveryRowOfEveryTableHasTheColumnsOfItsHeader() throws {
        let report = try report(try variedBundle(), capture: capture(written: 5, lost: [.notCaptured: 2]))

        let tables = report.sections.flatMap { self.tables($0.blocks) }
        XCTAssertGreaterThan(tables.count, 5)
        for table in tables {
            XCTAssertFalse(table.rows.isEmpty, "\(table.columns)")
            for row in table.rows {
                XCTAssertEqual(row.count, table.columns.count, "\(table.columns)")
            }
        }
    }

    func testTheSameSessionGivesTheSameReport() throws {
        let first = try report(try variedBundle())
        let second = try report(try variedBundle())

        XCTAssertEqual(first, second)
    }

    // MARK: - La sesión

    func testTheSubtitleNamesTheReleaseOrSaysItIsABaseline() throws {
        let audit = try report(try makeBundle([]))
        let baseline = try report(try makeBundle([], session: Fixtures.session(kind: .baseline, inspection: Self.notInspecting)))

        XCTAssertEqual(audit.subtitle, "Example · 2.4.0 (118) · session 7")
        XCTAssertEqual(baseline.subtitle, "Example · baseline · session 7")
    }

    func testTheSessionSectionSaysWhatWasRecordedAndUnderWhichConditions() throws {
        let blocks = try section(.session, of: try report(try variedBundle())).blocks

        XCTAssertEqual(value("Project", in: blocks), "Example")
        XCTAssertEqual(value("Kind", in: blocks), "audit")
        XCTAssertEqual(value("Release", in: blocks), "2.4.0 (118)")
        XCTAssertEqual(value("Started", in: blocks), EvidenceBundleFormat.timestamp(Fixtures.start))
        XCTAssertEqual(value("Device", in: blocks), "iPhone18,3")
        XCTAssertEqual(value("Recorded with TunnelVision", in: blocks), "1.0 (1)")
        XCTAssertEqual(value("Exported with TunnelVision", in: blocks), "1.1 (4)")
        XCTAssertEqual(value("Exported", in: blocks), EvidenceBundleFormat.timestamp(Self.exportedAt))
        XCTAssertEqual(value("TLS inspection", in: blocks), "on")
        XCTAssertEqual(value("Local CA trusted", in: blocks), "yes")
        XCTAssertNil(value("Notes", in: blocks))
        XCTAssertNil(value("App bundle identifier", in: blocks))
        XCTAssertTrue(blocks.contains(.paragraph(EvidenceWording.reportPinningConditions(supportsPinningEvidence: true))))
    }

    func testABaselineHasNoReleaseAndASessionWithoutATrustedCASaysPinningCannotBeRead() throws {
        let bundle = try makeBundle([], session: Fixtures.session(kind: .baseline, inspection: Self.notInspecting))
        let blocks = try section(.session, of: try report(bundle)).blocks

        XCTAssertEqual(value("Kind", in: blocks), "baseline")
        XCTAssertNil(value("Release", in: blocks))
        XCTAssertEqual(value("TLS inspection", in: blocks), "off")
        let pinning = EvidenceWording.reportPinningConditions(supportsPinningEvidence: false)
        XCTAssertTrue(blocks.contains(.paragraph(pinning)))
        XCTAssertTrue(pinning.hasPrefix("Nothing about certificate pinning can be read from this session"))
    }

    func testMarkersAndTheAllowlistAreTablesAndTheirAbsenceIsSaid() throws {
        let with = try section(.session, of: try report(try variedBundle())).blocks
        let without = try section(.session, of: try report(try makeBundle([]))).blocks

        XCTAssertEqual(
            tables(try blocks(under: "Markers", in: with)).first?.rows,
            [
                [EvidenceBundleFormat.timestamp(Fixtures.start.addingTimeInterval(4.5)), "consentGiven", ""],
                [EvidenceBundleFormat.timestamp(Fixtures.start.addingTimeInterval(6)), "custom", "Opened the diary"],
            ]
        )
        XCTAssertEqual(
            tables(try blocks(under: "Allowlist", in: with)).first?.rows,
            [["api.example.com", ""], ["bank.example.com", ""]]
        )
        XCTAssertEqual(try blocks(under: "Markers", in: without), [.paragraph(EvidenceWording.reportNoMarkers)])
        XCTAssertEqual(try blocks(under: "Allowlist", in: without), [.paragraph(EvidenceWording.reportNoAllowlist)])
    }

    // MARK: - Lo que el paquete ya dice

    func testTheMethodSectionQuotesTheBundlesOwnNotes() throws {
        let blocks = try section(.method, of: try report(try makeBundle([]))).blocks

        XCTAssertEqual(blocks, [
            .note(EvidenceSessionDocument.attributionNote),
            .note(EvidenceWording.verdictsNote),
            .note(EvidenceSessionDocument.contentsNote),
            .note(EvidenceFlowsDocument.contentsNote),
        ])
    }

    func testTheCatalogueIsCitedWithBothDocumentsTheirVersionsAndDates() throws {
        let blocks = try section(.catalogue, of: try report(try makeBundle([]))).blocks
        let all = facts(blocks)

        XCTAssertEqual(value("Catalogue", in: blocks), "tr-03161-1_3.0")
        XCTAssertEqual(all.filter { $0.label == "Document" }.map(\.value), ["BSI TR-03161-1", "BSI TR-02102-2"])
        XCTAssertEqual(all.filter { $0.label == "Version" }.map(\.value), ["3.0 (2024-03-25)", "2026-01 (2026-01-27)"])
        XCTAssertEqual(value("Lowest version accepted", in: blocks), "TLS 1.2")
        XCTAssertTrue(all.filter { $0.label.hasPrefix("SHA-256") }.allSatisfy { $0.value.count == 64 })
    }

    // MARK: - Los requisitos

    func testEveryRequirementIsListedWithItsVerdictAsFindingsJSONWritesIt() throws {
        let bundle = try variedBundle()
        let blocks = try section(.requirements, of: try report(bundle)).blocks

        XCTAssertEqual(
            tables(blocks).first?.rows,
            bundle.findings.requirements.map { [$0.id, $0.verdictStatement] }
        )
        for requirement in bundle.findings.requirements {
            let own = try self.blocks(under: "\(requirement.id) — \(requirement.title)", in: blocks)
            XCTAssertEqual(value("Verdict", in: own), requirement.verdictStatement, requirement.id)
            XCTAssertEqual(value("Test depth", in: own), requirement.testDepth, requirement.id)
        }
    }

    func testTheToolCoverageOfARequirementIsPrintedRightAfterItsVerdict() throws {
        let bundle = try variedBundle()
        let blocks = try section(.requirements, of: try report(bundle)).blocks

        var withCoverage = 0
        for requirement in bundle.findings.requirements {
            let own = facts(try self.blocks(under: "\(requirement.id) — \(requirement.title)", in: blocks))
            let verdict = try XCTUnwrap(own.firstIndex { $0.label == "Verdict" })
            if let toolCoverage = requirement.toolCoverage {
                withCoverage += 1
                XCTAssertEqual(own[verdict + 1].value, toolCoverage, requirement.id)
            } else {
                XCTAssertFalse(own.contains { $0.label.contains("toolCoverage") }, requirement.id)
                XCTAssertEqual(own[verdict].value, "Not assessed by this tool.", requirement.id)
            }
        }
        XCTAssertEqual(withCoverage, 5)
    }

    func testARequirementCitesItsFindingsAndHowManyConnectionsItsCheckLookedAt() throws {
        let bundle = try variedBundle()
        let blocks = try section(.requirements, of: try report(bundle)).blocks
        let written = Dictionary(uniqueKeysWithValues: bundle.findings.requirements.map { ($0.id, $0) })
        func own(_ id: String) throws -> [EvidenceReportBlock] {
            let requirement = try XCTUnwrap(written[id])
            return try self.blocks(under: "\(requirement.id) — \(requirement.title)", in: blocks)
        }

        let pinning = try own("O.Ntwk_4")
        XCTAssertEqual(
            value("Findings against it", in: pinning),
            try XCTUnwrap(written["O.Ntwk_4"]).contraryFindingIDs.joined(separator: ", ")
        )
        XCTAssertEqual(
            value("Findings in its support", in: pinning),
            try XCTUnwrap(written["O.Ntwk_4"]).supportingFindingIDs.joined(separator: ", ")
        )
        XCTAssertEqual(value("Check behind it", in: pinning), "Certificate pinning (pinning)")

        // Las nueve: una petición de HTTP en claro (3, el hallazgo), un ICMP (8, no aplica) y siete
        // con una lectura que solo existe si hubo cifrado — un handshake de TLS, una respuesta del
        // servidor (también la alerta del 7) o una versión de QUIC que cifra (6).
        let encryption = try own("O.Ntwk_1")
        XCTAssertEqual(value("Connections seen to be encrypted", in: encryption), "7")
        XCTAssertEqual(value("Connections not assessed", in: encryption), "0")
        XCTAssertEqual(value("Connections the check does not apply to", in: encryption), "1")
        XCTAssertNotNil(value("Findings against it", in: encryption))

        let outside = try own("O.Ntwk_3")
        XCTAssertNil(value("Check behind it", in: outside))
        XCTAssertNil(value("Connections not assessed", in: outside))
        XCTAssertNil(value("Findings against it", in: outside))
    }

    // MARK: - Los hallazgos

    func testFindingsThatStateTheSameGoUnderOneStatementWithARowEach() throws {
        let bundle = try makeBundle(
            [
                Fixtures.flow(id: 1, sni: "tracker.example.net", streamOpening: .tlsHandshake),
                Fixtures.flow(id: 2, sni: "ads.example.org", streamOpening: .tlsHandshake),
                Fixtures.flow(id: 3, sni: "tracker.example.net", streamOpening: .tlsHandshake),
            ],
            allowlist: ["api.example.com"]
        )
        let blocks = try section(.findings, of: try report(bundle)).blocks
        let statement = try XCTUnwrap(bundle.findings.findings.first).statement

        XCTAssertEqual(blocks, [
            .heading("hostNotInAllowlist"),
            .note(statement),
            .table(EvidenceReportTable(
                columns: ["Finding", "Stated about", "Connections", "Flows in flows.json"],
                rows: [
                    ["F1", "tracker.example.net", "2", "1, 3"],
                    ["F2", "ads.example.org", "1", "2"],
                ]
            )),
        ])
    }

    func testAWeakVersionIsPrintedWithWhereItWasReadAndAFindingWithNoSubjectHasNoColumnForIt() throws {
        let bundle = try makeBundle([
            Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls11, fromHelloRetryRequest: true)),
            Fixtures.flow(id: 2, tlsStatus: .inspected, serverTLS: Fixtures.negotiated(.tls10, source: .upstreamConnection)),
            Fixtures.flow(id: 3, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest),
        ])
        let blocks = try section(.findings, of: try report(bundle)).blocks
        let rows = tables(blocks).flatMap(\.rows)

        XCTAssertTrue(rows.contains(["F1", "TLS 1.1, serverHello, from a HelloRetryRequest", "1", "1"]))
        XCTAssertTrue(rows.contains(["F2", "TLS 1.0, upstreamConnection", "1", "2"]))
        let cleartext = tables(try self.blocks(under: "cleartextTraffic", in: blocks))
        XCTAssertEqual(cleartext.first?.columns, ["Finding", "Connections", "Flows in flows.json"])
        XCTAssertTrue(blocks.contains(.note("An HTTP request was observed in the clear.")))
    }

    func testAFindingWithMoreConnectionsThanTheLimitSaysHowManyAreNotPrintedAndWhere() throws {
        let flows = (1...7).map { Fixtures.flow(id: Int64($0), sni: "tracker.example.net", streamOpening: .tlsHandshake) }
        let bundle = try makeBundle(flows, allowlist: ["api.example.com"])

        let cut = tables(try section(.findings, of: try report(bundle, limits: try limits(flowIDs: 3))).blocks)
        let whole = tables(try section(.findings, of: try report(bundle, limits: try limits(flowIDs: 7))).blocks)

        XCTAssertEqual(
            cut.first?.rows,
            [["F1", "tracker.example.net", "7", "1, 2, 3. Connections not printed here: 4. The whole list is in findings.json."]]
        )
        XCTAssertEqual(whole.first?.rows, [["F1", "tracker.example.net", "7", "1, 2, 3, 4, 5, 6, 7"]])
    }

    func testNoFindingsIsSaidAndIsNotSaidAsNothingWrong() throws {
        let bundle = try makeBundle([Fixtures.flow(id: 1, streamOpening: .tlsHandshake)], allowlist: ["api.example.com"])
        let blocks = try section(.findings, of: try report(bundle)).blocks

        XCTAssertEqual(blocks, [.paragraph(EvidenceWording.reportNoFindings)])
        XCTAssertTrue(EvidenceWording.reportNoFindings.contains("not that nothing is wrong"))
    }

    // MARK: - Las comprobaciones

    func testEveryConnectionIsCountedOnceInEachCheck() throws {
        let bundle = try variedBundle()
        let blocks = try section(.checks, of: try report(bundle)).blocks

        XCTAssertEqual(blocks.first, .paragraph(EvidenceWording.reportChecksIntroduction))
        for check in FindingsCheck.allCases {
            let own = try self.blocks(under: EvidenceWording.reportCheckTitle(check), in: blocks)
            let counted = facts(own).compactMap { Int($0.value) }.reduce(0, +)
            XCTAssertEqual(counted, bundle.flows.flowCount, check.rawValue)

            let reasons = tables(own).flatMap(\.rows).compactMap { Int($0[1]) }.reduce(0, +)
            XCTAssertEqual(String(reasons), value("Connections not assessed", in: own), check.rawValue)
        }
    }

    func testTheConnectionsBehindTheFindingsOfACheckAreAddedUp() throws {
        // Dos hallazgos de la misma comprobación: un host de fuera con dos conexiones y una sin nombre.
        let bundle = try makeBundle(
            [
                Fixtures.flow(id: 1, sni: "tracker.example.net", streamOpening: .tlsHandshake),
                Fixtures.flow(id: 2, sni: "tracker.example.net", streamOpening: .tlsHandshake),
                Fixtures.flow(id: 3, sni: nil, streamOpening: .tlsHandshake),
            ],
            allowlist: ["api.example.com"]
        )
        let blocks = try section(.checks, of: try report(bundle)).blocks
        let host = try self.blocks(under: EvidenceWording.reportCheckTitle(.host), in: blocks)

        XCTAssertEqual(value("Connections behind a finding", in: host), "3")
        XCTAssertEqual(value("Connections to a host the allowlist covers", in: host), "0")
    }

    func testPinningHasNoCountOfConnectionsLookedAtAndSaysWhy() throws {
        let blocks = try section(.checks, of: try report(try variedBundle())).blocks
        let pinning = try self.blocks(under: EvidenceWording.reportCheckTitle(.pinning), in: blocks)

        XCTAssertNil(EvidenceWording.reportLookedAtLabel(.pinning))
        XCTAssertEqual(facts(pinning).map(\.label), [
            "Connections behind a finding", "Connections not assessed", "Connections the check does not apply to",
        ])
        XCTAssertTrue(pinning.contains(.paragraph(EvidenceWording.reportPinningOutcomesNote)))
        for check in FindingsCheck.allCases where check != .pinning {
            XCTAssertNotNil(EvidenceWording.reportLookedAtLabel(check))
        }
    }

    func testACheckSaysInASentenceWhyItCouldNotLookAndAtHowManyConnections() throws {
        let blocks = try section(.checks, of: try report(try variedBundle())).blocks
        let version = tables(try self.blocks(under: EvidenceWording.reportCheckTitle(.tlsVersion), in: blocks))
        let host = tables(try self.blocks(under: EvidenceWording.reportCheckTitle(.host), in: blocks))

        XCTAssertEqual(version.first?.columns, ["Why it could not be assessed", "Connections"])
        XCTAssertEqual(version.first?.rows, [
            [
                "The server negotiated TLS 1.3 with the tunnel's own connection. What the app would have "
                    + "negotiated was not observed: its ClientHello gave only a ceiling (up to TLS 1.2), "
                    + "not the list of versions it accepts.",
                "1",
            ],
            [
                "The QUIC version (0x00000001) was read only from the client, which proposes it: the "
                    + "server may have changed it.",
                "1",
            ],
            ["The server answered with an alert (code 70): no version was negotiated.", "1"],
            ["The connection shows signs of TLS, but no answer from the server was read.", "1"],
        ])
        XCTAssertEqual(host.first?.rows, [[
            "The name was deduced from a DNS reply, and its address was shared by names inside and "
                + "outside the allowlist. The name attributed to the connection is inside it.",
            "1",
        ]])
    }

    func testACheckThatCouldLookEverywhereHasNoTableOfReasons() throws {
        let bundle = try makeBundle(
            [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13), streamOpening: .tlsHandshake)],
            allowlist: ["api.example.com"]
        )
        let blocks = try section(.checks, of: try report(bundle)).blocks

        XCTAssertEqual(tables(try self.blocks(under: EvidenceWording.reportCheckTitle(.tlsVersion), in: blocks)), [])
        XCTAssertEqual(tables(try self.blocks(under: EvidenceWording.reportCheckTitle(.host), in: blocks)), [])
    }

    // MARK: - Las lecturas de TLS

    func testEveryTLSReadingIsPrintedWithItsHostAndWhereItWasRead() throws {
        let blocks = try section(.tlsReadings, of: try report(try variedBundle())).blocks

        XCTAssertEqual(blocks.first, .note(EvidenceWording.reportTLSReadingsNote))
        XCTAssertEqual(tables(blocks).first, EvidenceReportTable(
            columns: ["Host", "Name from", "Reading", "Read from", "Connections"],
            rows: [
                ["api.example.com", "sni", "TLS 1.3", "upstreamConnection", "1"],
                ["bank.example.com", "sni", "TLS 1.3", "serverHello", "1"],
                ["tracker.example.net", "sni", "TLS 1.0", "serverHello", "1"],
                ["tracker.example.net", "sni", "TLS 1.3", "serverHello", "1"],
                ["(no name)", "", "QUIC 0x00000001", "quic, read from the client", "1"],
            ]
        ))
        XCTAssertEqual(value("Connections with a reading", in: blocks), "5")
        XCTAssertEqual(value("Connections the server refused with an alert", in: blocks), "1")
        XCTAssertEqual(value("Connections with no TLS or QUIC reading", in: blocks), "3")
    }

    func testConnectionsWithTheSameHostAndReadingAreOneRowAndAnUnpublishedVersionIsItsWireValue() throws {
        let bundle = try makeBundle([
            Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13)),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(TLSProtocolVersion(rawValue: 0x7F1C), fromHelloRetryRequest: true)),
            Fixtures.flow(id: 3, serverTLS: Fixtures.negotiated(.tls13)),
            Fixtures.flow(
                id: 4,
                sni: nil,
                resolvedName: ResolvedFlowName(name: "cdn.example.net", otherNames: []),
                serverTLS: Fixtures.negotiated(.tls12)
            ),
        ])
        let blocks = try section(.tlsReadings, of: try report(bundle)).blocks

        XCTAssertEqual(tables(blocks).first?.rows, [
            ["api.example.com", "sni", "TLS 1.3", "serverHello", "2"],
            ["api.example.com", "sni", "0x7F1C", "serverHello, from a HelloRetryRequest", "1"],
            ["cdn.example.net", "dns", "TLS 1.2", "serverHello", "1"],
        ])
        XCTAssertNil(value("Connections with no TLS or QUIC reading", in: blocks))
        XCTAssertNil(value("Connections the server refused with an alert", in: blocks))
    }

    func testMoreReadingsThanTheLimitSaysHowManyRowsAreNotPrinted() throws {
        let flows = (1...4).map {
            Fixtures.flow(id: Int64($0), sni: "host\($0).example.com", serverTLS: Fixtures.negotiated(.tls13))
        }
        let blocks = try section(.tlsReadings, of: try report(try makeBundle(flows), limits: try limits(rows: 3))).blocks

        XCTAssertEqual(tables(blocks).first?.rows.count, 3)
        XCTAssertTrue(blocks.contains(.paragraph("Rows not printed here: 1. The whole list is in flows.json.")))
        XCTAssertEqual(value("Connections with a reading", in: blocks), "4")
    }

    func testASessionWithNoReadingHasNoTableAndSaysSo() throws {
        let blocks = try section(.tlsReadings, of: try report(try makeBundle([Fixtures.flow(id: 1)]))).blocks

        XCTAssertEqual(blocks, [.facts([
            EvidenceReportFact(label: "Connections with a reading", value: "0"),
            EvidenceReportFact(label: "Connections with no TLS or QUIC reading", value: "1"),
        ])])
    }

    // MARK: - La captura

    func testACompleteCaptureIsOneSentenceAndOneCount() throws {
        let document = capture(written: 42)
        let blocks = try section(.capture, of: try report(try makeBundle([]), capture: document)).blocks

        XCTAssertEqual(blocks, [
            .paragraph("Every packet the session recorded is in capture.pcapng."),
            .facts([EvidenceReportFact(label: "Packets recorded", value: "42")]),
            .note(EvidenceWording.captureContentsNote),
            .note(EvidenceWording.capturePacketCommentsNote),
        ])
    }

    func testAnIncompleteCaptureCountsOnlyTheReasonsThatHavePacketsUnderTheKeysOfCaptureJSON() throws {
        let document = capture(written: 5, lost: [.recordUnreadable: 2, .notCaptured: 3], beforeStart: 1)
        let blocks = try section(.capture, of: try report(try makeBundle([]), capture: document)).blocks

        XCTAssertEqual(blocks.first, .paragraph(EvidenceWording.reportCaptureStanding(
            .incomplete(written: 5, recorded: 10, missing: [])
        )))
        XCTAssertEqual(facts(blocks), [
            EvidenceReportFact(label: "Packets recorded", value: "10"),
            EvidenceReportFact(label: "Packets in capture.pcapng", value: "5"),
            EvidenceReportFact(label: "Never written to a capture file (notCaptured)", value: "3"),
            EvidenceReportFact(label: "Not readable back from its capture file (recordUnreadable)", value: "2"),
            EvidenceReportFact(label: "In the capture, from before the session started", value: "1"),
        ])
        for loss in EvidencePacketLoss.allCases {
            XCTAssertTrue(EvidenceWording.reportLabel(loss).hasSuffix("(\(loss))"), "\(loss)")
            XCTAssertTrue(EvidenceWording.captureContentsNote.contains("\(loss)"), "\(loss)")
        }
    }

    func testAnEmptyCaptureIsSaidWithoutCounts() throws {
        let blocks = try section(.capture, of: try report(try makeBundle([]), capture: capture())).blocks

        XCTAssertEqual(blocks.first, .paragraph("The session recorded no packets: capture.pcapng opens and is empty."))
        XCTAssertEqual(facts(blocks), [])
    }

    func testTheCaptureSectionAlwaysSaysThatWhatWasSentInTheClearIsReadableInIt() throws {
        for document in [capture(), capture(written: 3), capture(written: 1, lost: [.captureFileMissing: 4])] {
            let blocks = try section(.capture, of: try report(try makeBundle([]), capture: document)).blocks
            XCTAssertTrue(blocks.contains(.note(EvidenceWording.captureContentsNote)))
        }
        XCTAssertTrue(EvidenceWording.captureContentsNote.contains("what was sent in the clear is readable here"))
    }

    // MARK: - La redacción

    private static let everyReason: [String] = {
        let observation = TLSVersionObservation(
            version: TLSProtocolVersion(rawValue: 0x7F1C),
            basis: .serverHello(fromHelloRetryRequest: false)
        )
        let offers: [ClientOfferGap] = [
            .notRead, .encryptedClientHello, .ceilingOnly(.tls12), .listsWeakerVersion, .listNotConclusive,
        ]
        let version: [TLSVersionGap] = [
            .serverAnswerNotRead,
            .serverRefused(alert: 40),
            .unrecognisedVersion(observation),
            .quicVersionOnlyProposed(.v1),
            .unrecognisedQUICVersion(QUICVersion(rawValue: 0xFACE_B00C)),
        ] + offers.map { .appNegotiationNotObserved(upstream: .tls13, offer: $0) }
        let encryption: [EncryptionGap] = [
            .unrecognisedOpening, .openingNotRead, .datagramsNotRead,
            .unrecognisedQUICVersion(QUICVersion(rawValue: 0xFACE_B00C)),
        ]
        let host: [HostGap] = [
            .allowlistEmpty, .candidatesDisagree(attributedNameAllowed: true),
            .candidatesDisagree(attributedNameAllowed: false),
        ]
        let pinning: [PinningGap] = [
            .inspectionOff, .caNotTrusted, .quicNotInspected, .noInspectionOutcome, .outcomeWithoutAnnouncedName,
        ]
        let consent: [ConsentGap] = [.noConsentMarker, .betweenConsentMarkers]
        return version.map(EvidenceWording.reportReason)
            + encryption.map(EvidenceWording.reportReason)
            + host.map(EvidenceWording.reportReason)
            + pinning.map(EvidenceWording.reportReason)
            + consent.map(EvidenceWording.reportReason)
    }()

    func testEveryReasonACheckCouldNotLookHasASentenceOfItsOwn() {
        XCTAssertEqual(Self.everyReason.count, 24)
        XCTAssertEqual(Set(Self.everyReason).count, Self.everyReason.count)
        for reason in Self.everyReason {
            XCTAssertTrue(reason.hasSuffix("."), reason)
        }
        XCTAssertTrue(Self.everyReason.contains {
            $0.contains("0x7F1C") && $0.contains("serverHello")
        })
    }

    func testNothingTheReportPrintsSaysARequirementIsPassed() throws {
        let reports = [
            try report(try variedBundle(), capture: capture(written: 5, lost: [.notCaptured: 2, .captureFileMissing: 1, .recordUnreadable: 1], beforeStart: 1, afterEnd: 1)),
            try report(try makeBundle([]), capture: capture()),
            try report(try makeBundle([Fixtures.flow(id: 1, streamOpening: .tlsHandshake)], allowlist: ["api.example.com"])),
        ]
        let standings: [EvidenceCaptureStanding] = [
            .nothingRecorded, .complete(packets: 1), .incomplete(written: 1, recorded: 2, missing: []),
        ]
        let texts = reports.flatMap(everyText)
            + Self.everyReason
            + standings.map(EvidenceWording.reportCaptureStanding)
            + EvidenceReportSectionKind.allCases.map(EvidenceWording.reportSectionTitle)
            + FindingsCheck.allCases.map(EvidenceWording.reportCheckTitle)
            + FindingsCheck.allCases.compactMap(EvidenceWording.reportLookedAtLabel)
            + [true, false].map { EvidenceWording.reportPinningConditions(supportsPinningEvidence: $0) }
            + [
                EvidenceWording.reportNoFindings, EvidenceWording.reportNoMarkers,
                EvidenceWording.reportNoAllowlist, EvidenceWording.reportChecksIntroduction,
                EvidenceWording.reportPinningOutcomesNote, EvidenceWording.reportTLSReadingsNote,
            ]

        for text in texts {
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            for forbidden in ["pass", "passed", "passes", "compliant", "fulfilled", "satisfied"] {
                XCTAssertFalse(words.contains(forbidden), text)
            }
        }
    }

    func testPinningIsNeverWordedAboutTheApp() throws {
        let texts = everyText(of: try report(try variedBundle()))

        XCTAssertFalse(texts.contains { $0.lowercased().contains("the app pins") })
        XCTAssertTrue(texts.contains { $0.hasPrefix("A connection to this host refused the local CA's certificate.") })
    }
}
