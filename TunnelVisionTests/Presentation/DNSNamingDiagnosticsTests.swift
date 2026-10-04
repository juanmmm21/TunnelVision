import Foundation
import XCTest
import Shared

/// Tests de lo que *Session diagnostics* dice de los nombres que el túnel saca del DNS.
///
/// Lo que se afirma es la **frase**: con DNS cifrado no hay nada que leer, todos los contadores se
/// quedan a cero y una sesión entera sale sin nombres. Sin una conclusión escrita eso se lee como una
/// avería, y es justo lo que un informe de auditoría tendrá que decir de otra manera.
final class DNSNamingDiagnosticsTests: XCTestCase {

    // MARK: - Utilidades

    private func pipeline(
        packets: UInt64 = 500,
        _ configure: (inout DNSNameStats) -> Void = { _ in }
    ) -> PipelineStats {
        var stats = PipelineStats()
        stats.packetsHandled = packets
        configure(&stats.dnsNames)
        return stats
    }

    private func section(_ pipeline: PipelineStats, relay: RelayStats? = nil) throws -> DiagnosticsSection {
        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: pipeline, relay: relay))
        return try XCTUnwrap(sections.first { $0.id == "dnsNames" }, "falta la sección de nombres por DNS")
    }

    private static let everyVerdict: [DNSNamingVerdict] = [
        .noTraffic, .nothingToRead, .unreadable, .nothingToLearn, .learning, .naming
    ]

    // MARK: - El veredicto

    /// Sin un solo paquete no se afirma nada: unos contadores a cero **antes** de que pase tráfico no
    /// dicen que el DNS vaya cifrado.
    func testBeforeAnyTrafficNothingIsClaimed() {
        XCTAssertEqual(DiagnosticsPresentation.dnsNamingVerdict(for: PipelineStats()), .noTraffic)
    }

    /// El caso por el que existe la sección: tráfico pasando y ni un datagrama del puerto 53.
    func testTrafficWithNoDNSAtAllIsSaidToHaveHadNothingToRead() {
        XCTAssertEqual(DiagnosticsPresentation.dnsNamingVerdict(for: pipeline()), .nothingToRead)
    }

    func testDatagramsThatNeverParsedAreSaidToBeUnreadable() {
        let verdict = DiagnosticsPresentation.dnsNamingVerdict(for: pipeline { $0.unreadable = 6 })

        XCTAssertEqual(verdict, .unreadable)
    }

    /// Cada uno de los seis motivos por los que un mensaje legible no apunta nada acaba en la misma
    /// conclusión, y ninguno en «no se pudo leer»: el disector lo leyó.
    func testEveryReasonForIgnoringAReadableMessageMeansThereWasNothingToLearn() {
        let reasons: [DNSNameIngestion.Reason] = [
            .notAResponse, .unsupportedOpcode, .errorResponse,
            .unsupportedQuestion, .unusableName, .noAddresses
        ]

        for reason in reasons {
            let verdict = DiagnosticsPresentation.dnsNamingVerdict(for: pipeline { $0.count(.ignored(reason)) })

            XCTAssertEqual(verdict, .nothingToLearn, "\(reason)")
        }
    }

    /// Un mensaje legible desmiente «no se pudo leer» aunque otros no se dejasen.
    func testOneReadableMessageOutranksTheUnreadableOnes() {
        let verdict = DiagnosticsPresentation.dnsNamingVerdict(
            for: pipeline { $0.unreadable = 40; $0.errorResponses = 1 }
        )

        XCTAssertEqual(verdict, .nothingToLearn)
    }

    /// Direcciones apuntadas y ningún flujo hacia ellas todavía: lo normal en los primeros segundos,
    /// y no se confunde con estar nombrando.
    func testAddressesLearnedWithNoFlowYetIsItsOwnCase() {
        let verdict = DiagnosticsPresentation.dnsNamingVerdict(
            for: pipeline { $0.count(.recorded(addresses: 3)) }
        )

        XCTAssertEqual(verdict, .learning)
    }

    func testOneNamedFlowIsEnoughToSayNamingWorks() {
        let verdict = DiagnosticsPresentation.dnsNamingVerdict(
            for: pipeline {
                $0.count(.recorded(addresses: 2))
                $0.flowsNamed = 1
                $0.unreadable = 90
                $0.errorResponses = 30
            }
        )

        XCTAssertEqual(verdict, .naming)
    }

    // MARK: - La frase

    func testOnlyTheAbsenceOfTrafficHasNothingToSay() {
        XCTAssertNil(DiagnosticsPresentation.dnsNamingNote(for: .noTraffic))

        for verdict in Self.everyVerdict where verdict != .noTraffic {
            XCTAssertNotNil(DiagnosticsPresentation.dnsNamingNote(for: verdict), "\(verdict)")
        }
    }

    /// Cinco situaciones distintas con la misma frase serían cinco casos de adorno.
    func testEveryVerdictSaysSomethingDifferent() {
        let notes = Self.everyVerdict.compactMap(DiagnosticsPresentation.dnsNamingNote(for:))

        XCTAssertEqual(Set(notes).count, notes.count)
    }

    /// La ausencia de DNS legible se explica y no se presenta como una avería del producto: nombra
    /// el DNS cifrado y dice de qué otra forma se nombra un flujo.
    func testHavingNothingToReadIsExplainedAsEncryptedDNS() throws {
        let note = try XCTUnwrap(DiagnosticsPresentation.dnsNamingNote(for: .nothingToRead))

        XCTAssertTrue(note.contains("encrypted DNS"))
        XCTAssertTrue(note.contains("announce a host"))
    }

    /// Un nombre resuelto no es un SNI, y la frase del caso normal es el sitio donde se dice.
    func testTheNormalCaseSaysAResolvedNameIsNotAnAnnouncedOne() throws {
        let note = try XCTUnwrap(DiagnosticsPresentation.dnsNamingNote(for: .naming))

        XCTAssertTrue(note.contains("not announced"))
    }

    /// Un hecho se dice una vez: las cifras están en las filas, así que la frase no las repite.
    func testTheSentenceDoesNotRepeatTheFiguresOfItsRows() throws {
        let stats = pipeline {
            $0.repliesRecorded = 287
            $0.addressesRecorded = 731
            $0.flowsNamed = 1_038
        }
        let dnsNames = try section(stats)
        let note = try XCTUnwrap(dnsNames.note)

        for row in dnsNames.rows where row.value != "0" {
            XCTAssertFalse(note.contains(row.value), "la frase repite \(row.id)")
        }
    }

    // MARK: - La tabla

    func testTheSectionCarriesItsFiveReadingsAndTheSentenceOfItsVerdict() throws {
        let stats = pipeline {
            $0.repliesRecorded = 120
            $0.addressesRecorded = 310
            $0.flowsNamed = 600
            $0.unreadable = 2
        }
        let dnsNames = try section(stats)

        XCTAssertEqual(
            dnsNames.rows.map(\.id),
            [
                "dnsNames.repliesRecorded",
                "dnsNames.addressesRecorded",
                "dnsNames.flowsNamed",
                "dnsNames.repliesIgnored",
                "dnsNames.unreadable"
            ]
        )
        XCTAssertEqual(dnsNames.rows.map(\.value), ["120", "310", "600", "0", "2"])
        XCTAssertEqual(dnsNames.note, DiagnosticsPresentation.dnsNamingNote(for: .naming))
    }

    /// Los seis motivos van sumados en una fila: por separado son seis filas que una sesión sana
    /// llena de todas formas.
    func testTheReasonsForLearningNothingAreAddedUpInOneRow() throws {
        let stats = pipeline {
            $0.notAResponse = 1
            $0.unsupportedOpcode = 2
            $0.errorResponses = 4
            $0.unsupportedQuestions = 8
            $0.unusableNames = 16
            $0.withoutAddresses = 32
        }
        let dnsNames = try section(stats)

        XCTAssertEqual(dnsNames.rows.first { $0.id == "dnsNames.repliesIgnored" }?.value, "63")
    }

    /// Ninguna fila de aquí es trabajo nuestro perdido: un datagrama ilegible se reenvió y se grabó
    /// igual, así que no lleva la marca de avería ni cuando no está a cero.
    func testNothingInTheSectionIsMarkedAsAFault() throws {
        let stats = pipeline { $0.unreadable = 9; $0.errorResponses = 9 }

        XCTAssertTrue(try section(stats).rows.allSatisfy { $0.role == .reading })
    }

    /// Los contadores son del pipeline, así que la sección está aunque el relay no contestase — al
    /// revés que la de los nombres anunciados, que es suya.
    func testTheSectionIsThereWithoutTheRelay() throws {
        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: pipeline()))

        XCTAssertTrue(sections.contains { $0.id == "dnsNames" })
        XCTAssertFalse(sections.contains { $0.id == "names" })
    }

    /// Va pegada a los nombres anunciados: es la otra mitad de la misma pregunta.
    func testTheSectionFollowsTheAnnouncedNames() throws {
        let ids = DiagnosticsPresentation
            .sections(for: TunnelStats(pipeline: pipeline(), relay: RelayStats()))
            .map(\.id)
        let names = try XCTUnwrap(ids.firstIndex(of: "names"))

        XCTAssertEqual(ids.firstIndex(of: "dnsNames"), names + 1)
    }

    func testBeforeAnyTrafficTheSectionHasNoSentence() throws {
        XCTAssertNil(try section(PipelineStats()).note)
    }

    // MARK: - Lo sembrado

    /// Los contadores sembrados tienen que cuadrar entre sí como los de una sesión de verdad: cada
    /// respuesta de DNS que el relay recibió acabó en uno de los desenlaces del mapa de nombres.
    func testTheSeededCountersAddUpToTheRepliesTheRelayReceived() throws {
        let seeded = TunnelStatsFixture.make()
        let names = seeded.pipeline.dnsNames
        let relay = try XCTUnwrap(seeded.relay)

        XCTAssertEqual(
            names.repliesRecorded + names.repliesIgnored + names.unreadable,
            relay.dnsRepliesReceived
        )
        XCTAssertGreaterThanOrEqual(names.addressesRecorded, names.repliesRecorded)
        XCTAssertLessThan(names.flowsNamed, seeded.pipeline.flowsPersisted)
        XCTAssertEqual(DiagnosticsPresentation.dnsNamingVerdict(for: seeded.pipeline), .naming)
    }
}
