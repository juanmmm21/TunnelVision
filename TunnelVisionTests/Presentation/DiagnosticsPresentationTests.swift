import Foundation
import XCTest
import Shared

/// Tests del diagnóstico de la sesión.
///
/// Lo que se afirma aquí es **la conclusión**, no la tabla: el veredicto sobre la inspección es la
/// única pieza de esta pantalla que razona, y es exactamente la que hoy se saca delante de un
/// dispositivo con el depurador enganchado. Que se pueda probar en Simulator es el punto de todo el
/// incremento.
final class DiagnosticsPresentationTests: XCTestCase {

    // MARK: - Utilidades

    private func stats(_ configure: (inout RelayStats) -> Void) -> TunnelStats {
        var relay = RelayStats()
        configure(&relay)
        return TunnelStats(pipeline: PipelineStats(), relay: relay)
    }

    // MARK: - Cuándo no hay nada que concluir

    func testWithoutAMonitoringSessionThereIsNothingToDiagnose() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats { $0.inspectionCandidates = 10; $0.flowsInspected = 10 },
            isMonitoring: false
        )

        XCTAssertEqual(verdict, .notMonitoring)
    }

    /// Un relay ausente no es un relay a cero, y por eso no puede acabar en `.idle`: "no había a quien
    /// preguntar" y "no se inspeccionó nada" son respuestas distintas a la misma pregunta.
    func testAMissingRelayIsSaidToBeMissingAndNotSaidToBeIdle() {
        let verdict = DiagnosticsPresentation.verdict(
            for: TunnelStats(pipeline: PipelineStats(), relay: nil),
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .unavailable)
    }

    func testNoAnswerAtAllIsAlsoUnavailable() {
        XCTAssertEqual(DiagnosticsPresentation.verdict(for: nil, isMonitoring: true), .unavailable)
    }

    func testNoCandidateMeansIdle() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats { $0.tcpFlowsOpened = 40; $0.sniObserved = 12 },
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .idle)
    }

    // MARK: - El síntoma que hay que saber leer

    /// El caso caro: candidatos con nombre leído y **ni una** terminación. Es lo que se ve si el
    /// sandbox de iOS no deja levantar el listener de loopback, y también si la CA no está en el
    /// llavero de la extensión — las dos causas que la copia nombra.
    func testNamedCandidatesThatNeverBecomeTerminationsAreCalledOut() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats {
                $0.inspectionCandidates = 12
                $0.sniObserved = 12
                $0.inspectionsAbandoned = 12
            },
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .neverTerminates(named: true))
        XCTAssertEqual(DiagnosticsPresentation.headline(for: verdict).role, .warning)
    }

    /// El mismo cero de terminaciones, sin nombre: un 443 que no habla TLS. No es una avería, así que
    /// no se pinta como tal — confundir los dos casos es lo que mandaría a alguien a buscar un fallo
    /// donde solo hay una app hablando su propio protocolo.
    func testUnnamedCandidatesAreExplainedAndNotTreatedAsAFault() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats {
                $0.inspectionCandidates = 6
                $0.sniUnavailable = 6
                $0.inspectionsAbandoned = 6
            },
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .neverTerminates(named: false))
        XCTAssertNotEqual(DiagnosticsPresentation.headline(for: verdict).role, .warning)
    }

    // MARK: - Cuando sí se termina

    func testATerminationWithoutAnOutcomeYetIsSaidToBeStarting() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats {
                $0.inspectionCandidates = 3
                $0.sniObserved = 3
                $0.terminationsOpened = 3
            },
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .starting)
    }

    func testOneDecryptedFlowIsEnoughToSayInspectionWorks() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats {
                $0.inspectionCandidates = 9
                $0.sniObserved = 9
                $0.terminationsOpened = 8
                $0.flowsInspected = 1
                $0.flowsPinned = 5
                $0.terminationsFailed = 2
            },
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .working(inspected: 1))
        XCTAssertEqual(DiagnosticsPresentation.headline(for: verdict).role, .inspected)
    }

    /// Todo lo terminado rechazado por el cliente: el ADR 0003 visto desde los contadores. Se dice sin
    /// alarma porque el producto está haciendo exactamente lo que promete.
    func testEverythingPinnedIsExplainedAsPinningAndNotAsAFailure() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats {
                $0.inspectionCandidates = 4
                $0.sniObserved = 4
                $0.terminationsOpened = 4
                $0.flowsPinned = 4
            },
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .pinnedOnly(4))
        XCTAssertNotEqual(DiagnosticsPresentation.headline(for: verdict).role, .warning)
    }

    func testTerminationsThatKeepBreakingAreAWarning() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats {
                $0.inspectionCandidates = 5
                $0.sniObserved = 5
                $0.terminationsOpened = 5
                $0.terminationsFailed = 5
            },
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .failing(failed: 5, rolledBack: 0))
        XCTAssertEqual(DiagnosticsPresentation.headline(for: verdict).role, .warning)
    }

    /// La distinción que decide si quien lee sale a buscar un internet roto: unas terminaciones que
    /// se caen **antes de que el dispositivo vea nada** se deshacen, así que la inspección no
    /// funciona y aun así no se ha perdido una sola conexión. Es lo que se vería si el sistema no
    /// dejase levantar el listener local que la terminación necesita.
    func testFailuresUndoneInTimeSayThatBrowsingKeepsWorking() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats {
                $0.inspectionCandidates = 9
                $0.sniObserved = 9
                $0.terminationsOpened = 9
                $0.terminationsFailed = 9
                $0.terminationsRolledBack = 9
            },
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .failing(failed: 9, rolledBack: 9))
        let headline = DiagnosticsPresentation.headline(for: verdict)
        XCTAssertEqual(headline.title, "Inspection is not taking hold")
        XCTAssertTrue(
            headline.detail.contains("Browsing keeps working"),
            "sin esta frase, esta pantalla manda a buscar una avería de red que no existe: \(headline.detail)"
        )
    }

    /// Y si alguna no llegó a tiempo, el precio sí se paga navegando: gana el titular que lo dice.
    func testAFailureThatCouldNotBeUndoneKeepsTheLosingHeadline() {
        let verdict = DiagnosticsPresentation.verdict(
            for: stats {
                $0.inspectionCandidates = 9
                $0.sniObserved = 9
                $0.terminationsOpened = 9
                $0.terminationsFailed = 9
                $0.terminationsRolledBack = 8
            },
            isMonitoring: true
        )

        XCTAssertEqual(DiagnosticsPresentation.headline(for: verdict).title, "Inspection is breaking down")
    }

    // MARK: - La copia

    func testTheHeadlineOfAWorkingSessionCountsWhatWasDecrypted() {
        let headline = DiagnosticsPresentation.headline(for: .working(inspected: 1_204))

        XCTAssertEqual(headline.title, "Inspection is working")
        XCTAssertTrue(
            headline.detail.contains("1,204"),
            "el titular tiene que decir cuántas, y con el agrupado de millares de la app: \(headline.detail)"
        )
    }

    /// La copia del caso pinneado no puede leerse como una avería ni sugerir forzarlo: es el ADR 0003
    /// en palabras del usuario.
    func testThePinnedHeadlineSaysItIsByDesign() {
        let headline = DiagnosticsPresentation.headline(for: .pinnedOnly(3))

        XCTAssertTrue(headline.detail.contains("passed through untouched"), headline.detail)
        XCTAssertTrue(headline.detail.contains("by design"), headline.detail)
    }

    /// La degradación es silenciosa a propósito (el flujo vuelve al passthrough), así que la copia
    /// tiene que decirlo: si no, quien lea esto irá a buscar por qué "no funciona internet".
    func testTheNamedFailureSaysBrowsingKeepsWorking() {
        let headline = DiagnosticsPresentation.headline(for: .neverTerminates(named: true))

        XCTAssertTrue(headline.detail.contains("Browsing keeps working"), headline.detail)
    }

    /// Un error tipado no se enseña por su nombre de caso: `String(describing:)` daría
    /// `controlChannelFailed("…")`, que es código. Donde el sistema dio un texto, se enseña ese.
    func testTheReasonOfAFailureIsNeverTheNameOfItsCase() {
        XCTAssertEqual(
            DiagnosticsPresentation.diagnostic(for: .controlChannelFailed("XPC connection interrupted")),
            "XPC connection interrupted"
        )
        for error: TunnelControlError in [.permissionDenied, .notInstalled, .notRunning, .malformedResponse] {
            let reason = DiagnosticsPresentation.diagnostic(for: error)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(reason.contains("("), reason)
            XCTAssertTrue(reason.contains(" "), "\(reason) parece el nombre de un caso y no una frase")
        }
    }

    // MARK: - Las tablas

    func testTheInspectionCountersAreAllOnScreen() {
        let sections = DiagnosticsPresentation.sections(
            for: stats {
                $0.inspectionCandidates = 12
                $0.terminationsOpened = 9
                $0.inspectionsAbandoned = 3
                $0.pinnedHostSkips = 1
                $0.flowsInspected = 7
                $0.flowsPinned = 2
                $0.terminationsFailed = 1
            }
        )

        guard let inspection = sections.first(where: { $0.id == "inspection" }) else {
            return XCTFail("falta la sección de inspección")
        }
        // Los ocho que contestan "¿por qué no se inspecciona nada?" —y el último, además, "¿y cuánto
        // me cuesta?"—: ni uno menos.
        XCTAssertEqual(
            inspection.rows.map(\.id),
            [
                "inspection.candidates",
                "inspection.terminationsOpened",
                "inspection.flowsInspected",
                "inspection.flowsPinned",
                "inspection.abandoned",
                "inspection.pinnedHostSkips",
                "inspection.terminationsFailed",
                "inspection.terminationsRolledBack"
            ]
        )
        XCTAssertEqual(inspection.rows.first?.value, "12")
    }

    /// Sin relay no se pintan ceros del relay: las dos secciones que son suyas desaparecen, y las del
    /// pipeline —que sí contestó— se quedan.
    func testWithoutRelayCountersItsSectionsAreAbsentRatherThanZeroed() {
        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: PipelineStats()))

        let ids = sections.map(\.id)
        XCTAssertFalse(ids.contains("inspection"))
        XCTAssertFalse(ids.contains("names"))
        XCTAssertFalse(ids.contains("forwarding"))
        XCTAssertTrue(ids.contains("recording"))
        XCTAssertTrue(ids.contains("decrypted"))
    }

    /// Sin errores no hay sección de errores: una fila vacía diría que algo falló sin texto.
    func testTheErrorSectionOnlyExistsWhenThereIsAnError() {
        XCTAssertFalse(
            DiagnosticsPresentation.sections(for: TunnelStats()).contains { $0.id == "problems" }
        )

        var pipeline = PipelineStats()
        pipeline.lastStoreError = "database is locked"
        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: pipeline))

        guard let problems = sections.first(where: { $0.id == "problems" }) else {
            return XCTFail("falta la sección de errores")
        }
        XCTAssertEqual(problems.rows.map(\.value), ["database is locked"])
    }

    /// Las claves de fila alimentan la lista y los tests, así que no puede haber dos iguales: una
    /// repetida deja a SwiftUI reciclando la fila equivocada.
    func testEveryRowKeyIsUnique() {
        var pipeline = PipelineStats()
        pipeline.lastStoreError = "x"
        pipeline.lastCaptureError = "y"
        pipeline.lastRetentionError = "z"
        pipeline.lastPlaintextError = "w"
        let sections = DiagnosticsPresentation.sections(
            for: TunnelStats(pipeline: pipeline, relay: RelayStats())
        )

        let ids = sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
    }

    /// Un volumen se enseña como volumen y un contador como contador: 65.536 bytes son "66 KB" —en
    /// unidades decimales, la convención de red que usa toda la app— y no "65,536".
    func testVolumesAreShownAsVolumesAndCountsAsCounts() {
        var pipeline = PipelineStats()
        pipeline.plaintextBytesStored = 65_536
        pipeline.plaintextChunksStored = 65_536
        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: pipeline))

        let rows = sections.flatMap(\.rows)
        XCTAssertEqual(rows.first { $0.id == "decrypted.bytesStored" }?.value, "66 KB")
        XCTAssertEqual(rows.first { $0.id == "decrypted.stored" }?.value, "65,536")
    }

    // MARK: - El DNS: que dejar al dispositivo sin nombres deje de ser un silencio

    private func dnsStats(
        _ resolvers: ResolverStatus,
        queries: UInt64 = 0,
        replies: UInt64 = 0,
        withRelay: Bool = true
    ) -> TunnelStats {
        var relay = RelayStats()
        relay.dnsQueriesSent = queries
        relay.dnsRepliesReceived = replies
        return TunnelStats(
            pipeline: PipelineStats(),
            relay: withRelay ? relay : nil,
            resolvers: resolvers
        )
    }

    private func dnsVerdict(
        _ resolvers: ResolverStatus,
        queries: UInt64 = 0,
        replies: UInt64 = 0,
        withRelay: Bool = true
    ) -> ResolverVerdict {
        DiagnosticsPresentation.resolverVerdict(
            for: dnsStats(resolvers, queries: queries, replies: replies, withRelay: withRelay),
            isMonitoring: true
        )
    }

    /// Sin sesión no hay nada que afirmar del DNS, ni siquiera que falte: los resolvers anunciados son
    /// de un túnel encendido.
    func testWithoutASessionThereIsNothingToSayAboutNameResolution() {
        let verdict = DiagnosticsPresentation.resolverVerdict(
            for: dnsStats(ResolverStatus(announced: [], reportedWhenAnnounced: nil)),
            isMonitoring: false
        )

        XCTAssertEqual(verdict, .unknown)
        XCTAssertNil(DiagnosticsPresentation.resolverNotice(for: verdict))
    }

    /// Una respuesta sin la mitad del DNS tampoco afirma nada. Es la misma regla que gobierna al
    /// relay ausente: la ausencia no se pinta como un cero, porque aquí un cero significa que el
    /// dispositivo se quedó sin resolución de nombres.
    func testAReplyWithoutTheDNSHalfIsNotReadAsHavingAnnouncedNone() {
        let verdict = DiagnosticsPresentation.resolverVerdict(
            for: TunnelStats(pipeline: PipelineStats(), relay: RelayStats()),
            isMonitoring: true
        )

        XCTAssertEqual(verdict, .unknown)
        XCTAssertNil(DiagnosticsPresentation.resolverNotice(for: verdict))
    }

    /// El caso que hasta hoy era silencio absoluto: no se pudo ni preguntar, así que el túnel se
    /// declaró primario sin ofrecer resolución de nombres. Es una avería nuestra y se dice como tal.
    func testNotBeingAbleToReadTheSystemsResolversIsSaidOutLoud() {
        let verdict = dnsVerdict(ResolverStatus(announced: [], reportedWhenAnnounced: nil))

        XCTAssertEqual(verdict, .unreadable)
        guard let notice = DiagnosticsPresentation.resolverNotice(for: verdict) else {
            return XCTFail("un túnel sin DNS anunciado no puede no decir nada")
        }
        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(
            notice.detail.contains("monitoring off"),
            "quien se queda sin nombres necesita la salida, y es inmediata: \(notice.detail)"
        )
    }

    /// "No se pudo preguntar" y "no había ninguno" no son lo mismo, y por eso la lectura cruda es
    /// opcional: la primera es un fallo nuestro y la segunda una red sin resolvers.
    func testASystemWithNoResolversIsToldApartFromNotBeingAbleToAsk() {
        XCTAssertEqual(dnsVerdict(ResolverStatus(announced: [], reportedWhenAnnounced: [])), .noneReported)
    }

    /// El caso que la spec daba por alcanzable y nadie había visto: el sistema sí tiene resolvers y
    /// **ninguno** se puede anunciar por un túnel (aquí, un link-local IPv6, que sin zona no
    /// significa nada). Se separa de los otros dos porque es el único que justifica dejar que el
    /// usuario fije uno.
    func testResolversThatCannotBeAnnouncedAreDistinguishedFromHavingNone() {
        let verdict = dnsVerdict(
            ResolverStatus(announced: [], reportedWhenAnnounced: ["fe80::1", "127.0.0.1"])
        )

        XCTAssertEqual(verdict, .noneUsable(reported: ["fe80::1", "127.0.0.1"]))
        XCTAssertEqual(DiagnosticsPresentation.resolverNotice(for: verdict)?.role, .warning)
    }

    /// Lo normal no se anuncia: una pantalla que celebra que todo va bien enseña a ignorarse, y esta
    /// existe para que se mire cuando dice algo.
    func testResolvingNamesNormallySaysNothing() {
        let verdict = dnsVerdict(
            ResolverStatus(announced: ["192.168.1.1"], reportedWhenAnnounced: ["192.168.1.1"]),
            queries: 40,
            replies: 39
        )

        XCTAssertEqual(verdict, .announcing(["192.168.1.1"]))
        XCTAssertNil(DiagnosticsPresentation.resolverNotice(for: verdict))
    }

    /// **El fallo confirmado en hardware**: se enciende el túnel en Wi-Fi, se sale de casa, el túnel no
    /// consigue aprender los resolvers de la red nueva y las consultas se quedan sin contestar. Se
    /// afirma con **causa y síntoma a la vez**, que es lo que lo hace un hecho.
    func testANetworkChangeThatCouldNotBeLearnedAndBreaksLookupsIsCalledOut() {
        let verdict = dnsVerdict(
            ResolverStatus(
                announced: ["192.168.1.1"],
                reportedWhenAnnounced: ["192.168.1.1"],
                networkChanges: 1,
                resolversRelearned: 0
            ),
            queries: 12,
            replies: 0
        )

        XCTAssertEqual(verdict, .stale(queries: 12, networkChanges: 1))
        guard let notice = DiagnosticsPresentation.resolverNotice(for: verdict) else {
            return XCTFail("un DNS de la red anterior no puede quedarse sin decir")
        }
        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(
            notice.detail.contains("off and on again"),
            "hay una salida y es un gesto, no una explicación: \(notice.detail)"
        )
    }

    /// Un cambio de red que **sí** se aprendió no puede acabar en "estás usando el DNS de antes": el
    /// túnel ya demostró que sabe ponerse al día, así que si las consultas siguen sin contestarse la
    /// causa es otra y decir la equivocada manda a hacer un gesto que no arregla nada.
    func testANetworkChangeThatWasLearnedIsNotBlamedForBrokenLookups() {
        let verdict = dnsVerdict(
            ResolverStatus(
                announced: ["10.0.0.1"],
                reportedWhenAnnounced: ["10.0.0.1"],
                networkChanges: 2,
                resolversRelearned: 1
            ),
            queries: 9,
            replies: 0
        )

        XCTAssertEqual(verdict, .notAnswering(queries: 9))
    }

    /// Y sin ningún cambio de red, unas consultas sin respuesta son eso y nada más: se dicen sin
    /// inventarles una causa.
    func testLookupsWithNoRepliesAreReportedWithoutGuessingTheCause() {
        let verdict = dnsVerdict(
            ResolverStatus(announced: ["1.1.1.1"], reportedWhenAnnounced: ["1.1.1.1"]),
            queries: 6,
            replies: 0
        )

        XCTAssertEqual(verdict, .notAnswering(queries: 6))
        XCTAssertEqual(DiagnosticsPresentation.resolverNotice(for: verdict)?.role, .warning)
    }

    /// Una consulta sin contestar en el instante de mirar está **en vuelo**, y dos son un reintento.
    /// Avisar ahí sería una alarma que se dispara sola cada vez que alguien abre la pantalla mientras
    /// el teléfono trabaja.
    func testAHandfulOfLookupsInFlightIsNotCalledAFailure() {
        XCTAssertEqual(
            dnsVerdict(
                ResolverStatus(announced: ["1.1.1.1"], reportedWhenAnnounced: ["1.1.1.1"]),
                queries: 3,
                replies: 0
            ),
            .announcing(["1.1.1.1"])
        )
    }

    /// Sin la mitad del relay no hay par de consultas y respuestas que mirar, así que no se afirma que
    /// el DNS falle: unos contadores ausentes no son unos contadores a cero.
    func testWithoutTheRelayCountersNoDNSFailureIsClaimed() {
        XCTAssertEqual(
            dnsVerdict(
                ResolverStatus(
                    announced: ["1.1.1.1"],
                    reportedWhenAnnounced: ["1.1.1.1"],
                    networkChanges: 3
                ),
                withRelay: false
            ),
            .announcing(["1.1.1.1"])
        )
    }

    /// La tabla del DNS: las tres listas y los dos contadores que **son la medición viva** de si el
    /// reanuncio funciona. Ninguna lista se queda en blanco: "ninguno" y "no se pudo leer" son cosas
    /// distintas y las dos se dicen con palabras.
    func testTheNameResolutionTableShowsTheListsAndTheReannouncementCounters() {
        let sections = DiagnosticsPresentation.sections(
            for: dnsStats(
                ResolverStatus(
                    announced: [],
                    reportedWhenAnnounced: ["fe80::1"],
                    reportedNow: nil,
                    networkChanges: 2,
                    resolversRelearned: 1,
                    reannounceFailures: 0
                )
            )
        )

        XCTAssertEqual(sections.first?.id, "dns", "el DNS va delante de la inspección")
        guard let dns = sections.first(where: { $0.id == "dns" }) else {
            return XCTFail("falta la sección de resolución de nombres")
        }
        XCTAssertEqual(
            dns.rows.map(\.id),
            [
                "dns.announced",
                "dns.reportedWhenAnnounced",
                "dns.reportedNow",
                "dns.networkChanges",
                "dns.resolversRelearned",
                "dns.reannounceFailures"
            ]
        )
        XCTAssertEqual(
            dns.rows.map(\.value),
            ["None", "fe80::1", "Could not be read", "2", "1", "0"]
        )
    }

    /// Varias direcciones se leen separadas por coma, en el orden en que el sistema las prefiere.
    func testSeveralResolversAreListedInTheSystemsOwnOrder() {
        let sections = DiagnosticsPresentation.sections(
            for: dnsStats(
                ResolverStatus(
                    announced: ["192.168.1.1", "2001:db8::53"],
                    reportedWhenAnnounced: ["192.168.1.1", "2001:db8::53"]
                )
            )
        )

        let rows = sections.flatMap(\.rows)
        XCTAssertEqual(rows.first { $0.id == "dns.announced" }?.value, "192.168.1.1, 2001:db8::53")
    }

    /// El par que sostiene el veredicto se enseña también como números, y juntos: por separado no
    /// dicen nada, y es su relación la que explica una página que no carga.
    func testTheLookupPairIsOnScreenTogether() {
        let sections = DiagnosticsPresentation.sections(
            for: dnsStats(
                ResolverStatus(announced: ["1.1.1.1"], reportedWhenAnnounced: ["1.1.1.1"]),
                queries: 80,
                replies: 78
            )
        )

        let rows = sections.flatMap(\.rows)
        XCTAssertEqual(rows.first { $0.id == "forwarding.dnsQueriesSent" }?.value, "80")
        XCTAssertEqual(rows.first { $0.id == "forwarding.dnsRepliesReceived" }?.value, "78")
    }

    /// Un reanuncio que falla deja al túnel **sin ajustes de red**: el dispositivo sigue navegando y la
    /// captura se queda muerta. Es una avería silenciosa, así que su texto va donde van los errores.
    func testAFailedReannouncementIsShownAmongTheErrors() {
        let sections = DiagnosticsPresentation.sections(
            for: dnsStats(
                ResolverStatus(
                    announced: ["1.1.1.1"],
                    reportedWhenAnnounced: ["1.1.1.1"],
                    networkChanges: 1,
                    reannounceFailures: 1,
                    lastReannounceError: "The operation couldn’t be completed."
                )
            )
        )

        guard let problems = sections.first(where: { $0.id == "problems" }) else {
            return XCTFail("falta la sección de errores")
        }
        XCTAssertEqual(
            problems.rows.first { $0.id == "problems.reannounce" }?.value,
            "The operation couldn’t be completed."
        )
    }

    /// Sin la mitad del DNS, su sección no se pinta vacía: no hay nada que enseñar y un "ninguno"
    /// afirmaría que el túnel dejó al dispositivo sin nombres.
    func testWithoutTheDNSHalfItsSectionIsAbsent() {
        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: PipelineStats()))

        XCTAssertFalse(sections.map(\.id).contains("dns"))
    }

    // MARK: - Las tres listas del DNS, cuando son una

    /// El caso normal: el sistema contesta lo que el túnel acaba de anunciar, porque el túnel es el
    /// interfaz primario. Tres filas idénticas no son una comparación, así que la comparación se hace
    /// y sale **una** fila — con el pie que explica por qué basta.
    func testThreeAgreeingListsAreShownAsOneRowWithItsReason() {
        let addresses = ["192.0.2.53", "2001:db8::53"]
        let sections = DiagnosticsPresentation.sections(
            for: dnsStats(
                ResolverStatus(
                    announced: addresses,
                    reportedWhenAnnounced: addresses,
                    reportedNow: addresses
                )
            )
        )

        guard let dns = sections.first(where: { $0.id == "dns" }) else {
            return XCTFail("falta la sección de resolución de nombres")
        }
        XCTAssertEqual(
            dns.rows.map(\.id),
            ["dns.inUse", "dns.networkChanges", "dns.resolversRelearned", "dns.reannounceFailures"]
        )
        XCTAssertEqual(dns.rows.first?.value, "192.0.2.53, 2001:db8::53")
        XCTAssertNotNil(dns.note, "una sola lista tiene que explicar por qué es una sola")
    }

    /// Y en cuanto dejan de coincidir vuelven las tres con su nombre, porque **ésa** es la avería que
    /// la sección existe para enseñar: un cambio de red que el túnel no aprendió.
    func testListsThatStopMatchingAreShownApartAndWithoutTheNote() {
        let sections = DiagnosticsPresentation.sections(
            for: dnsStats(
                ResolverStatus(
                    announced: ["192.0.2.53"],
                    reportedWhenAnnounced: ["192.0.2.53"],
                    reportedNow: ["198.51.100.53"]
                )
            )
        )

        guard let dns = sections.first(where: { $0.id == "dns" }) else {
            return XCTFail("falta la sección de resolución de nombres")
        }
        XCTAssertEqual(
            dns.rows.prefix(3).map(\.id),
            ["dns.announced", "dns.reportedWhenAnnounced", "dns.reportedNow"]
        )
        XCTAssertNil(dns.note, "con las tres a la vista cada fila ya lleva su nombre")
    }

    /// Una lista que **no se pudo leer** no coincide con nada. Darla por coincidente borraría la
    /// distinción que `ResolverStatus` guarda con más cuidado: no es lo mismo no tener resolvers que
    /// no haber podido preguntar.
    func testAListThatCouldNotBeReadNeverAgrees() {
        let unreadable = ResolverStatus(
            announced: ["192.0.2.53"],
            reportedWhenAnnounced: ["192.0.2.53"],
            reportedNow: nil
        )

        XCTAssertEqual(DiagnosticsPresentation.listing(for: unreadable), .diverging)
    }

    // MARK: - Qué cifra es una avería

    /// Un contador de pérdidas **a cero** es una lectura como cualquier otra: la marca dice que algo
    /// está pasando ahora, y a cero no está pasando nada.
    func testAFailureCounterAtZeroIsAnOrdinaryReading() {
        let sections = DiagnosticsPresentation.sections(
            for: TunnelStats(pipeline: PipelineStats(), relay: RelayStats())
        )

        let rows = sections.flatMap(\.rows)
        for id in ["recording.storeFailures", "recording.captureFailures", "inspection.terminationsFailed"] {
            XCTAssertEqual(rows.first { $0.id == id }?.role, .reading, id)
        }
    }

    /// Y en cuanto no está a cero se separa del resto de la tabla, que es lo que permite contestar
    /// "¿qué va mal?" bajando por ella en vez de leyendo cuarenta y ocho números.
    func testAFailureCounterThatIsNotZeroIsMarked() {
        var pipeline = PipelineStats()
        pipeline.captureFailures = 3
        pipeline.packetsDropped = 12
        var relay = RelayStats()
        relay.terminationsFailed = 4
        relay.emitterFailures = 1

        let rows = DiagnosticsPresentation
            .sections(for: TunnelStats(pipeline: pipeline, relay: relay))
            .flatMap(\.rows)

        for id in [
            "recording.captureFailures",
            "recording.packetsDropped",
            "inspection.terminationsFailed",
            "forwarding.emitterFailures"
        ] {
            XCTAssertEqual(rows.first { $0.id == id }?.role, .fault, id)
        }
    }

    /// Lo que **no** es una avería aunque no esté a cero, y es la mitad de la regla: un host que
    /// rechaza nuestro certificado es ADR 0003 cumpliéndose, un límite que recorta es un límite
    /// obrando, y una conexión que la red tira no la ha perdido esta app. Marcar eso en ámbar
    /// convertiría la marca en el adorno que la Timeline le quitó a su insignia.
    func testWhatIsNotAFaultIsNotMarkedEvenWhenItIsNotZero() {
        var pipeline = PipelineStats()
        pipeline.plaintextBytesDropped = 4_096
        pipeline.capturesReclaimed = 5
        pipeline.plaintextChunksExpired = 30
        var relay = RelayStats()
        relay.flowsPinned = 22
        relay.tcpResetsToDevice = 9
        relay.connectionFailures = 6
        relay.terminationsRolledBack = 4

        let rows = DiagnosticsPresentation
            .sections(for: TunnelStats(pipeline: pipeline, relay: relay))
            .flatMap(\.rows)

        for id in [
            "inspection.flowsPinned",
            "inspection.terminationsRolledBack",
            "forwarding.tcpResetsToDevice",
            "forwarding.connectionFailures",
            "decrypted.bytesDropped",
            "recording.capturesReclaimed",
            "decrypted.expired"
        ] {
            XCTAssertEqual(rows.first { $0.id == id }?.role, .reading, id)
        }
    }

    /// El símbolo y el color de una fila marcada no se oyen, así que lo que dicen tiene que estar en
    /// el texto que compone el núcleo puro.
    func testAMarkedRowSaysOutLoudWhatItsSymbolMeans() {
        let spoken = DiagnosticsPresentation.faultDescription(label: "Capture failures", value: "3")

        XCTAssertTrue(spoken.contains("Capture failures"))
        XCTAssertTrue(spoken.contains("3"))
        XCTAssertNotEqual(spoken, "Capture failures: 3", "la frase que dice qué significa la marca falta")
    }

    /// Los mensajes de la sección de errores no son copia nuestra sino lo que contestó el sistema, y
    /// llevan el papel que lo dice: se leen carácter a carácter y se copian tal cual.
    func testTheSystemsOwnMessagesAreMarkedAsSuch() {
        var pipeline = PipelineStats()
        pipeline.lastCaptureError = "The file couldn’t be saved."
        pipeline.lastStoreError = "database is locked"

        let sections = DiagnosticsPresentation.sections(for: TunnelStats(pipeline: pipeline))

        guard let problems = sections.first(where: { $0.id == "problems" }) else {
            return XCTFail("falta la sección de errores")
        }
        XCTAssertTrue(problems.rows.allSatisfy { $0.role == .systemText })
    }
}
