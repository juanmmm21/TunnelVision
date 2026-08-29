import Foundation
import XCTest
import Shared

/// Tests del view model del diagnóstico de la sesión.
///
/// El canal de control va guionizado —en Simulator no hay túnel al otro lado—, y lo que se afirma
/// aquí son las dos reglas sobre qué se conserva: un fallo de consulta **no** borra lo último cierto,
/// y parar el túnel **sí**, porque esos números eran de aquella sesión.
@MainActor
final class DiagnosticsViewModelTests: XCTestCase {

    // MARK: - Utilidades

    private func counters(inspected: UInt64 = 0, candidates: UInt64 = 0) -> TunnelStats {
        var relay = RelayStats()
        relay.inspectionCandidates = candidates
        relay.sniObserved = candidates
        relay.terminationsOpened = inspected
        relay.flowsInspected = inspected
        var pipeline = PipelineStats()
        pipeline.packetsHandled = 1_000
        return TunnelStats(pipeline: pipeline, relay: relay)
    }

    /// Un canal que contesta lo que se le diga, y que puede cambiar de respuesta entre dos consultas.
    private final class Channel: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<ControlResponse, TunnelControlError>

        init(_ outcome: Result<ControlResponse, TunnelControlError>) { self.outcome = outcome }

        func set(_ new: Result<ControlResponse, TunnelControlError>) {
            lock.lock(); outcome = new; lock.unlock()
        }

        func send(_ command: ControlCommand) throws -> ControlResponse {
            lock.lock(); defer { lock.unlock() }
            return try outcome.get()
        }
    }

    private func makeViewModel(_ channel: Channel) -> DiagnosticsViewModel {
        DiagnosticsViewModel(send: { command in try channel.send(command) })
    }

    // MARK: - La consulta

    func testTheCountersArriveAndBecomeTheVerdict() async {
        let viewModel = makeViewModel(Channel(.success(.stats(counters(inspected: 3, candidates: 4)))))
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.stats?.relay?.flowsInspected, 3)
        XCTAssertEqual(viewModel.headline.title, "Inspection is working")
        XCTAssertNil(viewModel.failure)
        XCTAssertFalse(viewModel.sections.isEmpty)
    }

    /// Regla 1: lo último cierto se queda. Los números de hace un momento siguen siendo lo que pasó;
    /// lo que se añade es por qué no hay unos más nuevos.
    func testAFailedQueryKeepsTheLastKnownCountersAndSaysWhy() async {
        let channel = Channel(.success(.stats(counters(inspected: 2, candidates: 2))))
        let viewModel = makeViewModel(channel)
        viewModel.tunnelStateDidChange(to: .live)
        await viewModel.refresh()

        channel.set(.failure(.controlChannelFailed("sesión caída")))
        await viewModel.refresh()

        XCTAssertEqual(viewModel.stats?.relay?.flowsInspected, 2)
        XCTAssertNotNil(viewModel.failure)
        XCTAssertEqual(viewModel.headline.title, "Inspection is working")
    }

    /// Sin un solo contador que leer, el fallo **es** el titular: no hay nada de lo que concluir nada.
    func testWithNoCountersAtAllTheFailureIsTheHeadline() async {
        let viewModel = makeViewModel(Channel(.failure(.controlChannelFailed("XPC caído"))))
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.headline.title, "The tunnel did not answer")
        XCTAssertEqual(viewModel.headline.role, .warning)
        XCTAssertTrue(viewModel.sections.isEmpty)
        // El motivo es lo que dijo el sistema, no el nombre del caso del error: `controlChannelFailed`
        // en pantalla es código, no una explicación.
        XCTAssertEqual(viewModel.headline.detail, "XPC caído")
    }

    /// Sin túnel no se pregunta. Preguntar igualmente enseñaba el fallo del canal —"no hay sesión"— en
    /// lugar de lo único cierto: que no hay sesión de la que diagnosticar nada. Se vio en el
    /// Simulator, donde nunca hay túnel.
    func testWithoutAMonitoringSessionNothingIsAsked() async {
        let channel = Channel(.failure(.permissionDenied))
        let viewModel = makeViewModel(channel)
        viewModel.tunnelStateDidChange(to: .off)

        await viewModel.refresh()

        XCTAssertNil(viewModel.failure)
        XCTAssertNil(viewModel.stats)
        XCTAssertEqual(viewModel.headline.title, "Nothing to diagnose yet")
    }

    /// Que el túnel no esté corriendo no es un fallo: es la carrera normal entre la pantalla y
    /// `stopTunnel`, y lo que deja es una pantalla sin contadores, no una con un error.
    func testNoSessionIsNotReportedAsAFailure() async {
        let viewModel = makeViewModel(Channel(.success(.notRunning)))
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.refresh()

        XCTAssertNil(viewModel.stats)
        XCTAssertNil(viewModel.failure)
    }

    func testAnUnexpectedReplyIsRecordedWithoutLosingTheCounters() async {
        let channel = Channel(.success(.stats(counters(inspected: 1, candidates: 1))))
        let viewModel = makeViewModel(channel)
        viewModel.tunnelStateDidChange(to: .live)
        await viewModel.refresh()

        channel.set(.success(.ok))
        await viewModel.refresh()

        XCTAssertEqual(viewModel.stats?.relay?.flowsInspected, 1)
        XCTAssertEqual(viewModel.failure, DiagnosticsPresentation.unexpectedReply)
    }

    // MARK: - Lo que dura una sesión

    /// Regla 2: los contadores nacen a cero con cada sesión, así que apagar el túnel se los lleva.
    /// Dejarlos habría enseñado el resultado de una inspección terminada bajo un titular que dice que
    /// no hay nada que diagnosticar.
    func testStoppingTheTunnelDropsTheCountersOfThatSession() async {
        let viewModel = makeViewModel(Channel(.success(.stats(counters(inspected: 5, candidates: 5)))))
        viewModel.tunnelStateDidChange(to: .live)
        await viewModel.refresh()
        XCTAssertNotNil(viewModel.stats)

        viewModel.tunnelStateDidChange(to: .off)

        XCTAssertNil(viewModel.stats)
        XCTAssertTrue(viewModel.sections.isEmpty)
        XCTAssertEqual(viewModel.headline.title, "Nothing to diagnose yet")
    }

    /// El aviso del DNS se va con la sesión por lo mismo que los contadores: un túnel apagado no está
    /// anunciando resolvers de ninguna red, así que decir que los suyos son de la anterior sería
    /// hablar de algo que ya no existe — y encima manda a apagar lo que ya está apagado.
    func testStoppingTheTunnelAlsoTakesAwayTheDNSNotice() async {
        var stats = counters(inspected: 1, candidates: 1)
        stats.resolvers = ResolverStatus(
            announced: ["192.168.1.1"],
            reportedWhenAnnounced: ["192.168.1.1"],
            networkChanges: 1,
            resolversRelearned: 0
        )
        stats.relay?.dnsQueriesSent = 20
        stats.relay?.dnsRepliesReceived = 0
        let viewModel = makeViewModel(Channel(.success(.stats(stats))))
        viewModel.tunnelStateDidChange(to: .live)
        await viewModel.refresh()
        XCTAssertEqual(
            viewModel.resolverNotice?.title,
            "The tunnel is using the previous network's DNS servers"
        )

        viewModel.tunnelStateDidChange(to: .off)

        XCTAssertNil(viewModel.resolverNotice)
    }

    /// Y una transición que **no** es apagar no toca nada: un `reasserting` mientras el túnel se
    /// restablece no puede vaciar la pantalla.
    func testATransitionThatIsNotStoppingKeepsTheCounters() async {
        let viewModel = makeViewModel(Channel(.success(.stats(counters(inspected: 5, candidates: 5)))))
        viewModel.tunnelStateDidChange(to: .live)
        await viewModel.refresh()

        viewModel.tunnelStateDidChange(to: .live)

        XCTAssertNotNil(viewModel.stats)
    }
}
