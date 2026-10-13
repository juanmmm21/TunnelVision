import Foundation
import XCTest
import Shared

/// Tests de lo que *Session diagnostics* dice de los nombres que el túnel lee del arranque de QUIC.
///
/// Lo que se afirma es la **frase**: «no hubo QUIC», «no se abrió ningún Initial», «no se llegó a
/// leer» y «no anunciaba nombre» dejan los flujos igual de sin nombre, y lo único que los separa es
/// la relación entre los contadores. Y que la frase del caso normal diga dónde está el límite: se
/// abren los Initial del cliente y nada más.
final class QUICNamingDiagnosticsTests: XCTestCase {

    // MARK: - Utilidades

    private func pipeline(
        packets: UInt64 = 500,
        _ configure: (inout QUICNameStats) -> Void = { _ in }
    ) -> PipelineStats {
        var stats = PipelineStats()
        stats.packetsHandled = packets
        configure(&stats.quicNames)
        return stats
    }

    private func section(_ pipeline: PipelineStats, relay: RelayStats? = nil) throws -> DiagnosticsSection {
        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: pipeline, relay: relay))
        return try XCTUnwrap(sections.first { $0.id == "quicNames" }, "falta la sección de nombres de QUIC")
    }

    private static let everyVerdict: [QUICNamingVerdict] = [
        .noTraffic, .nothingToRead, .notOpening, .reading, .notReadable, .nothingAnnounced, .naming
    ]

    // MARK: - El veredicto

    func testBeforeAnyTrafficNothingIsClaimed() {
        XCTAssertEqual(DiagnosticsPresentation.quicNamingVerdict(for: PipelineStats()), .noTraffic)
    }

    /// Tráfico pasando y ningún Initial de un cliente: no es una avería, es que nada habló QUIC.
    func testTrafficWithNoQUICAtAllIsSaidToHaveHadNothingToRead() {
        XCTAssertEqual(DiagnosticsPresentation.quicNamingVerdict(for: pipeline()), .nothingToRead)
    }

    func testInitialsThatNeverOpenedAreTheirOwnCase() {
        let verdict = DiagnosticsPresentation.quicNamingVerdict(for: pipeline { $0.initialsNotOpened = 6 })

        XCTAssertEqual(verdict, .notOpening)
    }

    /// Un flujo que agotó sus Initial **sin abrir ninguno** ha terminado sin nombre, pero lo que
    /// hay que decir de él es que no se abrió nada, no que no cupiese lo que llevaba.
    func testAFlowThatSpentItsInitialsWithoutOpeningOneIsStillNotOpening() {
        let verdict = DiagnosticsPresentation.quicNamingVerdict(
            for: pipeline { $0.initialsNotOpened = 8; $0.initialsExhausted = 1 }
        )

        XCTAssertEqual(verdict, .notOpening)
    }

    /// Con Initial saltados por cupo delante no se puede decir que no hubo QUIC.
    func testInitialsSkippedAtCapacityCountAsSeen() {
        let verdict = DiagnosticsPresentation.quicNamingVerdict(
            for: pipeline { $0.initialsSkippedAtCapacity = 3 }
        )

        XCTAssertEqual(verdict, .notOpening)
    }

    /// Initial abiertos y ningún desenlace: el ClientHello de Chrome ocupa dos, así que esto es lo
    /// que se ve entre el primero y el segundo.
    func testOpenedInitialsWithNoOutcomeYetIsReading() {
        let verdict = DiagnosticsPresentation.quicNamingVerdict(
            for: pipeline { $0.initialsOpened = 2; $0.initialsNotOpened = 5 }
        )

        XCTAssertEqual(verdict, .reading)
    }

    func testEveryWayOfNotReadingAClientHelloToTheEndIsNotReadable() {
        let reasons: [WritableKeyPath<QUICNameStats, UInt64>] = [
            \.unreadableClientHello, \.cryptoStreamAbandoned, \.initialsExhausted
        ]

        for reason in reasons {
            let verdict = DiagnosticsPresentation.quicNamingVerdict(
                for: pipeline { $0.initialsOpened = 4; $0[keyPath: reason] = 1 }
            )

            XCTAssertEqual(verdict, .notReadable, "\(reason)")
        }
    }

    /// Un ClientHello leído entero desmiente «no se pudo leer» aunque otros no se dejasen: el
    /// lector funciona, y lo que faltaba era el anuncio.
    func testOneClientHelloReadWholeOutranksTheUnreadOnes() {
        let verdict = DiagnosticsPresentation.quicNamingVerdict(
            for: pipeline {
                $0.initialsOpened = 90
                $0.withoutServerName = 1
                $0.unreadableClientHello = 40
            }
        )

        XCTAssertEqual(verdict, .nothingAnnounced)
    }

    func testOneNamedFlowIsEnoughToSayNamingWorks() {
        let verdict = DiagnosticsPresentation.quicNamingVerdict(
            for: pipeline {
                $0.initialsOpened = 2
                $0.flowsNamed = 1
                $0.withoutServerName = 30
                $0.initialsExhausted = 30
                $0.initialsNotOpened = 300
                $0.initialsSkippedAtCapacity = 300
            }
        )

        XCTAssertEqual(verdict, .naming)
    }

    /// Los reinicios no deciden nada por sí solos: un Retry es parte de un arranque normal.
    func testRestartsAloneClaimNothing() {
        let verdict = DiagnosticsPresentation.quicNamingVerdict(for: pipeline { $0.readsRestarted = 7 })

        XCTAssertEqual(verdict, .nothingToRead)
    }

    // MARK: - La frase

    func testOnlyTheAbsenceOfTrafficHasNothingToSay() {
        XCTAssertNil(DiagnosticsPresentation.quicNamingNote(for: .noTraffic))

        for verdict in Self.everyVerdict where verdict != .noTraffic {
            XCTAssertNotNil(DiagnosticsPresentation.quicNamingNote(for: verdict), "\(verdict)")
        }
    }

    func testEveryVerdictSaysSomethingDifferent() {
        let notes = Self.everyVerdict.compactMap(DiagnosticsPresentation.quicNamingNote(for:))

        XCTAssertEqual(Set(notes).count, notes.count)
    }

    /// La ausencia de QUIC se explica y manda a donde sí están los nombres de esa sesión.
    func testHavingNothingToReadSaysWhatQUICIsAndWhereTheOtherNamesAre() throws {
        let note = try XCTUnwrap(DiagnosticsPresentation.quicNamingNote(for: .nothingToRead))

        XCTAssertTrue(note.contains("HTTP/3"))
        XCTAssertTrue(note.contains("under Names"))
    }

    /// ADR 0003 y 0006 dichos donde se lee: se abre el arranque y la conexión no se descifra.
    func testTheNormalCaseDrawsTheLineAtTheOpeningPackets() throws {
        let note = try XCTUnwrap(DiagnosticsPresentation.quicNamingNote(for: .naming))

        XCTAssertTrue(note.contains("nothing else"))
        XCTAssertTrue(note.contains("never decrypted"))
    }

    /// Ninguno de los casos sin nombre deja pensar que el flujo se perdió: o se dice que conserva
    /// el nombre del DNS, o que se reenvía intacto.
    func testEveryUnnamedCaseSaysWhatTheConnectionsKeep() throws {
        for verdict in [QUICNamingVerdict.notOpening, .notReadable, .nothingAnnounced] {
            let note = try XCTUnwrap(DiagnosticsPresentation.quicNamingNote(for: verdict))

            XCTAssertTrue(note.contains("keep the name a lookup gave them"), "\(verdict)")
        }
    }

    func testTheSentenceDoesNotRepeatTheFiguresOfItsRows() throws {
        let quicNames = try section(TunnelStatsFixture.make().pipeline)
        let note = try XCTUnwrap(quicNames.note)

        for row in quicNames.rows where row.value != "0" {
            XCTAssertFalse(note.contains(row.value), "la frase repite \(row.id)")
        }
    }

    // MARK: - La tabla

    func testTheSectionCarriesItsSevenReadingsAndTheSentenceOfItsVerdict() throws {
        let stats = pipeline {
            $0.flowsNamed = 600
            $0.withoutServerName = 9
            $0.initialsOpened = 1_240
            $0.initialsNotOpened = 31
            $0.readsRestarted = 3
            $0.initialsSkippedAtCapacity = 2
        }
        let quicNames = try section(stats)

        XCTAssertEqual(
            quicNames.rows.map(\.id),
            [
                "quicNames.flowsNamed",
                "quicNames.withoutServerName",
                "quicNames.flowsNotRead",
                "quicNames.initialsOpened",
                "quicNames.initialsNotOpened",
                "quicNames.readsRestarted",
                "quicNames.initialsSkippedAtCapacity"
            ]
        )
        XCTAssertEqual(quicNames.rows.map(\.value), ["600", "9", "0", "1,240", "31", "3", "2"])
        XCTAssertEqual(quicNames.note, DiagnosticsPresentation.quicNamingNote(for: .naming))
    }

    /// Las tres formas de no leer un ClientHello entero van sumadas, y lo leído sin nombre aparte:
    /// es la distinción que la sección existe para enseñar.
    func testTheWaysOfNotReadingAreAddedUpApartFromTheOnesWithoutAName() throws {
        let stats = pipeline {
            $0.withoutServerName = 1
            $0.unreadableClientHello = 2
            $0.cryptoStreamAbandoned = 4
            $0.initialsExhausted = 8
        }
        let rows = try section(stats).rows

        XCTAssertEqual(rows.first { $0.id == "quicNames.flowsNotRead" }?.value, "14")
        XCTAssertEqual(rows.first { $0.id == "quicNames.withoutServerName" }?.value, "1")
    }

    /// Nada de aquí es trabajo nuestro perdido: un Initial que no se abre o que se salta se reenvió
    /// igual (ADR 0006), así que ninguna fila lleva la marca de avería ni cuando no está a cero.
    func testNothingInTheSectionIsMarkedAsAFault() throws {
        let stats = pipeline {
            $0.initialsNotOpened = 9
            $0.initialsSkippedAtCapacity = 9
            $0.unreadableClientHello = 9
            $0.cryptoStreamAbandoned = 9
            $0.initialsExhausted = 9
        }

        XCTAssertTrue(try section(stats).rows.allSatisfy { $0.role == .reading })
    }

    /// Los contadores son del pipeline, así que la sección está aunque el relay no contestase.
    func testTheSectionIsThereWithoutTheRelay() throws {
        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: pipeline()))

        XCTAssertTrue(sections.contains { $0.id == "quicNames" })
        XCTAssertFalse(sections.contains { $0.id == "names" })
    }

    /// Va pegada a los nombres que anuncia TCP: los dos son nombres anunciados.
    func testTheSectionFollowsTheNamesAnnouncedOverTCP() throws {
        let ids = DiagnosticsPresentation
            .sections(for: TunnelStats(pipeline: pipeline(), relay: RelayStats()))
            .map(\.id)
        let names = try XCTUnwrap(ids.firstIndex(of: "names"))

        XCTAssertEqual(ids.firstIndex(of: "quicNames"), names + 1)
    }

    func testBeforeAnyTrafficTheSectionHasNoSentence() throws {
        XCTAssertNil(try section(PipelineStats()).note)
    }

    // MARK: - Lo sembrado

    /// Los contadores sembrados tienen que cuadrar entre sí como los de una sesión de verdad: un
    /// flujo nombrado abrió al menos un Initial, y los flujos QUIC leídos caben en los UDP que el
    /// relay abrió y que no eran consultas de DNS.
    func testTheSeededCountersFitInsideTheUDPFlowsThatAreNotLookups() throws {
        let seeded = TunnelStatsFixture.make()
        let names = seeded.pipeline.quicNames
        let relay = try XCTUnwrap(seeded.relay)

        XCTAssertGreaterThan(names.flowsNamed, 0)
        XCTAssertLessThanOrEqual(names.flowsNamed + names.withoutServerName, names.initialsOpened)
        XCTAssertLessThanOrEqual(
            names.flowsNamed + names.flowsLeftUnnamed,
            relay.udpFlowsOpened - relay.dnsQueriesSent
        )
        XCTAssertEqual(DiagnosticsPresentation.quicNamingVerdict(for: seeded.pipeline), .naming)
    }

    /// La sesión sembrada es una que funciona: enseña cada forma de quedarse sin nombre, y ninguna
    /// le gana a los flujos nombrados.
    func testTheSeededSessionShowsEveryRowWithSomethingButTheQuota() throws {
        let rows = try section(TunnelStatsFixture.make().pipeline).rows

        for row in rows where row.id != "quicNames.initialsSkippedAtCapacity" {
            XCTAssertNotEqual(row.value, "0", row.id)
        }
        XCTAssertEqual(rows.first { $0.id == "quicNames.initialsSkippedAtCapacity" }?.value, "0")
    }
}
