import Foundation
import XCTest
import Shared

/// Tests del controlador del túnel (M9) contra el doble de `TunnelProviderManaging`.
///
/// Lo que se prueba aquí es la orquestación: el orden instalar→arrancar, que una denegación no acabe
/// en un callejón sin salida, que el stream del sistema mande sobre el estado, y que el canal de
/// control viaje por el codec real (`Shared/IPC/ControlChannel.swift`) y no por bytes inventados.
@MainActor
final class TunnelControllerTests: XCTestCase {

    // MARK: - Estado inicial

    func testRefreshTakesTheStateFromTheSavedProfile() async {
        let fake = FakeTunnelProviderManager(status: .connected)
        let controller = TunnelController(manager: fake)

        await controller.refresh()

        XCTAssertEqual(controller.state, .live)
    }

    func testRefreshReportsALoadFailureAsAnActionableState() async {
        let fake = FakeTunnelProviderManager()
        await fake.setLoadError(.configurationFailed("no se pudo leer el perfil"))
        let controller = TunnelController(manager: fake)

        await controller.refresh()

        XCTAssertEqual(controller.state, .failed(.configurationFailed("no se pudo leer el perfil")))
    }

    // MARK: - Encender

    func testStartingWithoutAProfileInstallsItFirst() async {
        let fake = FakeTunnelProviderManager(status: .notInstalled)
        let controller = TunnelController(manager: fake)

        await controller.startMonitoring()

        let calls = await fake.calls
        XCTAssertEqual(calls.first, .loadStatus)
        XCTAssertTrue(calls.contains(.install(.default)), "el perfil tiene que instalarse antes de arrancar")
        guard let installIndex = calls.firstIndex(of: .install(.default)),
              let startIndex = calls.firstIndex(of: .start) else {
            return XCTFail("faltan llamadas: \(calls)")
        }
        XCTAssertLessThan(installIndex, startIndex)
        XCTAssertEqual(controller.state, .starting)
    }

    func testStartingWithAnInstalledProfileDoesNotReinstallIt() async {
        let fake = FakeTunnelProviderManager(status: .disconnected)
        let controller = TunnelController(manager: fake)

        await controller.startMonitoring()

        let calls = await fake.calls
        XCTAssertFalse(calls.contains(.install(.default)))
        XCTAssertTrue(calls.contains(.start))
        XCTAssertEqual(controller.state, .starting)
    }

    /// Denegar el diálogo del sistema deja un estado que la vista puede explicar, y **no** se intenta
    /// arrancar un túnel que no existe.
    func testADeniedPermissionIsAnActionableStateAndNothingIsStarted() async {
        let fake = FakeTunnelProviderManager(status: .notInstalled)
        await fake.setInstallError(.permissionDenied)
        let controller = TunnelController(manager: fake)

        await controller.startMonitoring()

        XCTAssertEqual(controller.state, .failed(.permissionDenied))
        let calls = await fake.calls
        XCTAssertFalse(calls.contains(.start))
    }

    /// El "Try again" de la UI tiene que volver a pasar por la instalación: lo que faltaba era el
    /// permiso, no el arranque. Si el reintento se decidiera mirando el `state` (que ya no es
    /// `.notInstalled` sino `.failed`), intentaría arrancar un perfil inexistente.
    func testRetryingAfterADenialAttemptsTheInstallAgain() async {
        let fake = FakeTunnelProviderManager(status: .notInstalled)
        await fake.setInstallError(.permissionDenied)
        let controller = TunnelController(manager: fake)
        await controller.startMonitoring()

        await fake.setInstallError(nil)
        await controller.startMonitoring()

        let installs = await fake.calls.filter { $0 == .install(.default) }
        XCTAssertEqual(installs.count, 2)
        XCTAssertEqual(controller.state, .starting)
    }

    func testAFailedStartKeepsTheSystemMessage() async {
        let fake = FakeTunnelProviderManager(status: .disconnected)
        await fake.setStartError(.startFailed("permission entitlement missing"))
        let controller = TunnelController(manager: fake)

        await controller.startMonitoring()

        XCTAssertEqual(controller.state, .failed(.startFailed("permission entitlement missing")))
    }

    /// Un segundo toque en un túnel ya encendido no pide un segundo arranque.
    func testStartingAnAlreadyLiveTunnelIsANoOp() async {
        let fake = FakeTunnelProviderManager(status: .connected)
        let controller = TunnelController(manager: fake)

        await controller.startMonitoring()

        let calls = await fake.calls
        XCTAssertFalse(calls.contains(.start))
        XCTAssertEqual(controller.state, .live)
    }

    /// Una configuración inválida se detecta antes de tocar el sistema: no tiene sentido enseñarle al
    /// usuario un diálogo de permisos para guardar un perfil que no puede funcionar.
    func testAnInvalidConfigurationNeverReachesTheSystem() async {
        let fake = FakeTunnelProviderManager(status: .notInstalled)
        var broken = TunnelConfiguration.default
        broken.providerBundleIdentifier = ""
        let controller = TunnelController(manager: fake, configuration: broken)

        await controller.startMonitoring()

        let calls = await fake.calls
        XCTAssertTrue(calls.isEmpty, "no debería haber llegado ninguna llamada: \(calls)")
        guard case .failed(.configurationFailed) = controller.state else {
            return XCTFail("se esperaba un fallo de configuración, hay \(controller.state)")
        }
    }

    // MARK: - Apagar

    func testStoppingLeavesTheStateSyncedWithTheSystem() async {
        let fake = FakeTunnelProviderManager(status: .connected)
        await fake.setStatusAfterStop(.disconnected)
        let controller = TunnelController(manager: fake)
        await controller.refresh()

        await controller.stopMonitoring()

        let calls = await fake.calls
        XCTAssertTrue(calls.contains(.stop))
        XCTAssertEqual(controller.state, .off)
    }

    func testAFailedStopIsReported() async {
        let fake = FakeTunnelProviderManager(status: .connected)
        await fake.setStopError(.configurationFailed("busy"))
        let controller = TunnelController(manager: fake)

        await controller.stopMonitoring()

        XCTAssertEqual(controller.state, .failed(.configurationFailed("busy")))
    }

    // MARK: - Observación del sistema

    func testTheSystemStreamDrivesTheState() async throws {
        let fake = FakeTunnelProviderManager(status: .disconnected)
        let controller = TunnelController(manager: fake)
        controller.startObservingStatus()
        defer { controller.stopObservingStatus() }

        fake.emit(.connecting)
        try await waitFor(.starting, in: controller)
        fake.emit(.connected)
        try await waitFor(.live, in: controller)
        fake.emit(.disconnected)
        try await waitFor(.off, in: controller)
    }

    /// El estado publicado conserva el fallo aunque el sistema mande el `disconnected` que lo
    /// acompaña; es la misma regla de `TunnelStatePolicy.next`, comprobada de extremo a extremo.
    func testAVisibleFailureSurvivesTheStreamsDisconnect() async throws {
        let fake = FakeTunnelProviderManager(status: .disconnected)
        await fake.setStartError(.startFailed("boom"))
        let controller = TunnelController(manager: fake)
        controller.startObservingStatus()
        defer { controller.stopObservingStatus() }
        await controller.startMonitoring()
        XCTAssertEqual(controller.state, .failed(.startFailed("boom")))

        fake.emit(.disconnected)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(controller.state, .failed(.startFailed("boom")))
    }

    /// Observar dos veces no abre dos observadores: si lo hiciera, el `stop` cerraría solo uno y el
    /// otro seguiría escribiendo estado a espaldas de la vista.
    func testObservingTwiceRegistersASingleObserver() async throws {
        let fake = FakeTunnelProviderManager(status: .disconnected)
        let controller = TunnelController(manager: fake)
        controller.startObservingStatus()
        controller.startObservingStatus()
        fake.emit(.connected)
        try await waitFor(.live, in: controller)

        controller.stopObservingStatus()
        fake.emit(.disconnected)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(controller.state, .live, "un observador superviviente habría movido el estado")
    }

    // MARK: - Canal de control

    func testACommandTravelsThroughTheRealCodecAndItsResponseComesBack() async throws {
        let fake = FakeTunnelProviderManager(status: .connected)
        await fake.setControlOutcome(.success(try ControlResponse.ok.encoded()))
        let controller = TunnelController(manager: fake)

        let response = try await controller.send(.setTLSInspectionEnabled(true))

        XCTAssertEqual(response, .ok)
        let commands = try await fake.sentCommands()
        XCTAssertEqual(commands, [.setTLSInspectionEnabled(true)])
    }

    /// Sin respuesta no hay sesión al otro lado: es la carrera normal entre la UI y `stopTunnel`, y se
    /// distingue de una avería para no alarmar al usuario con un error que no lo es.
    func testAnAbsentReplyIsReportedAsNotRunning() async {
        let fake = FakeTunnelProviderManager(status: .disconnected)
        let controller = TunnelController(manager: fake)

        await assertThrowsAsync { try await controller.send(.rotateCapture) } _: { error in
            XCTAssertEqual(error as? TunnelControlError, .notRunning)
        }
    }

    func testAReplyThatIsNotAControlResponseIsRejected() async {
        let fake = FakeTunnelProviderManager(status: .connected)
        await fake.setControlOutcome(.success(Data([0x00, 0x01, 0x02])))
        let controller = TunnelController(manager: fake)

        await assertThrowsAsync { try await controller.send(.stats) } _: { error in
            XCTAssertEqual(error as? TunnelControlError, .malformedResponse)
        }
    }

    func testATransportFailurePropagatesTyped() async {
        let fake = FakeTunnelProviderManager(status: .connected)
        await fake.setControlOutcome(.failure(.controlChannelFailed("XPC caído")))
        let controller = TunnelController(manager: fake)

        await assertThrowsAsync { try await controller.send(.stats) } _: { error in
            XCTAssertEqual(error as? TunnelControlError, .controlChannelFailed("XPC caído"))
        }
    }

    // MARK: - Utilidades

    /// Espera a que el estado publicado alcance `expected`. El stream del sistema es asíncrono, así que
    /// no basta con un `yield`: se sondea con un tope para que un fallo sea un fallo y no un cuelgue.
    private func waitFor(
        _ expected: TunnelState,
        in controller: TunnelController,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if controller.state == expected { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("el estado se quedó en \(controller.state), se esperaba \(expected)", file: file, line: line)
    }

    /// `XCTAssertThrowsError` no admite expresiones `async`; esta es la versión mínima equivalente.
    /// Vive dentro de la clase (aislada al `MainActor`) porque las expresiones que recibe lo están.
    private func assertThrowsAsync<T>(
        _ expression: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ handler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("se esperaba un error y no hubo ninguno", file: file, line: line)
        } catch {
            handler(error)
        }
    }
}
