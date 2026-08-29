import Foundation
import XCTest

/// Tests del núcleo puro del control del túnel (M9): el mapeo status→estado, la conservación de un
/// fallo visible y la clasificación de los errores de NetworkExtension.
final class TunnelStatePolicyTests: XCTestCase {

    // MARK: - Mapeo

    func testEveryStatusMapsToItsState() {
        let expected: [(TunnelStatus, TunnelState)] = [
            (.notInstalled, .notInstalled),
            (.disconnected, .off),
            (.connecting, .starting),
            (.reasserting, .starting),
            (.connected, .live),
            (.disconnecting, .stopping)
        ]

        for (status, state) in expected {
            XCTAssertEqual(TunnelStatePolicy.state(for: status), state, "status \(status)")
        }
    }

    /// `reasserting` es el túnel restableciéndose: instalado y encendido, pero sin cursar tráfico de
    /// forma fiable. Enseñarlo como "monitorizando" sería una mentira que el usuario pilla al ver que
    /// no aparecen conexiones.
    func testReassertingIsNotReportedAsLive() {
        XCTAssertNotEqual(TunnelStatePolicy.state(for: .reasserting), .live)
        XCTAssertEqual(TunnelStatePolicy.state(for: .reasserting), .starting)
    }

    // MARK: - Conservación del fallo

    /// NetworkExtension acompaña casi todos los fallos de un `disconnected`; mapearlo sin más borraría
    /// el error justo cuando la UI iba a enseñarlo, y el usuario se quedaría ante un interruptor que
    /// no hace nada y no explica nada.
    func testAFailureSurvivesTheDisconnectThatFollowsIt() {
        let failed = TunnelState.failed(.permissionDenied)

        XCTAssertEqual(TunnelStatePolicy.next(from: failed, status: .disconnected), failed)
        XCTAssertEqual(TunnelStatePolicy.next(from: failed, status: .notInstalled), failed)
        XCTAssertEqual(TunnelStatePolicy.next(from: failed, status: .disconnecting), failed)
    }

    /// Pero un túnel que arranca de verdad deja obsoleto el fallo anterior.
    func testAnActiveStatusClearsAPreviousFailure() {
        let failed = TunnelState.failed(.startFailed("boom"))

        XCTAssertEqual(TunnelStatePolicy.next(from: failed, status: .connecting), .starting)
        XCTAssertEqual(TunnelStatePolicy.next(from: failed, status: .connected), .live)
        XCTAssertEqual(TunnelStatePolicy.next(from: failed, status: .reasserting), .starting)
    }

    func testWithoutAPreviousFailureTheNextStateIsJustTheMapping() {
        for current in [TunnelState.notInstalled, .off, .starting, .live, .stopping] {
            for status in [TunnelStatus.notInstalled, .disconnected, .connecting, .connected, .reasserting, .disconnecting] {
                XCTAssertEqual(
                    TunnelStatePolicy.next(from: current, status: status),
                    TunnelStatePolicy.state(for: status),
                    "desde \(current) con \(status)"
                )
            }
        }
    }

    // MARK: - Clasificación de errores

    /// Denegar el diálogo del sistema no es una avería: llega como
    /// `NEVPNErrorDomain`/`configurationReadWriteFailed` y merece un estado propio para que la UI
    /// pueda ofrecer el "Try again" en vez de un mensaje de error críptico.
    func testTheDenialOfTheSystemPromptIsRecognised() {
        let error = TunnelControlError.classifying(
            domain: TunnelControlError.vpnErrorDomain,
            code: TunnelControlError.vpnConfigurationReadWriteFailedCode,
            message: "permission denied"
        )
        XCTAssertEqual(error, .permissionDenied)
    }

    func testOtherVPNErrorsKeepTheirMessage() {
        let error = TunnelControlError.classifying(
            domain: TunnelControlError.vpnErrorDomain,
            code: 1,
            message: "configuration invalid"
        )
        XCTAssertEqual(error, .configurationFailed("configuration invalid"))
    }

    /// El mismo código en otro dominio no es una denegación: no se puede clasificar por número suelto.
    func testTheCodeAloneIsNotEnoughToClaimADenial() {
        let error = TunnelControlError.classifying(
            domain: NSPOSIXErrorDomain,
            code: TunnelControlError.vpnConfigurationReadWriteFailedCode,
            message: "io error"
        )
        XCTAssertEqual(error, .configurationFailed("io error"))
    }

    // MARK: - Configuración

    func testTheDefaultConfigurationIsValid() throws {
        XCTAssertNoThrow(try TunnelConfiguration.default.validate())
        XCTAssertEqual(TunnelConfiguration.default.providerBundleIdentifier, "com.juanmmm21.tunnelvision.PacketTunnel")
    }

    /// Un campo en blanco produce un perfil que iOS guarda pero no sabe explicar ni resolver.
    func testABlankFieldIsRejected() {
        var missingProvider = TunnelConfiguration.default
        missingProvider.providerBundleIdentifier = "   "
        var missingServer = TunnelConfiguration.default
        missingServer.serverAddress = ""
        var missingDescription = TunnelConfiguration.default
        missingDescription.localizedDescription = "\n"

        for configuration in [missingProvider, missingServer, missingDescription] {
            XCTAssertThrowsError(try configuration.validate()) { error in
                guard case .configurationFailed = error as? TunnelControlError else {
                    return XCTFail("se esperaba configurationFailed, llegó \(error)")
                }
            }
        }
    }
}
