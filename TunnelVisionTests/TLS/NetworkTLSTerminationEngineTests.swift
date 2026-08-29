import Foundation
import Security
import Shared
import XCTest

/// Lo único de la conformidad de producción del motor que se puede afirmar sin dispositivo: **el orden
/// en que hace sus dos cosas**. El resto —la sesión de loopback con el leaf y la `NWConnection` con TLS
/// bajo confianza del sistema— se valida por compilación, como `NetworkRelayConnection` y el propio
/// provider, y su comportamiento vivo lo prueban `LoopbackTLSServerSessionTests` y
/// `TLSTerminationConnectionTests`.
final class NetworkTLSTerminationEngineTests: XCTestCase {

    private static let endpoint = IPEndpoint(
        address: IPAddress(version: .v4, bytes: [93, 184, 216, 34]),
        port: 443
    )

    /// Primero el leaf y solo después la red: si la CA no puede emitir para ese host no hay inspección
    /// posible, y abrir la conexión al servidor real sería estrenar tráfico por un flujo que va a acabar
    /// en passthrough de todas formas.
    func testWithoutALeafNothingIsDialled() async {
        let dialled = DialRecorder()
        let engine = NetworkTLSTerminationEngine(
            ca: FailingMinter(),
            queue: DispatchQueue(label: "tests.tls.engine"),
            makeUpstream: { endpoint, serverName, _ in dialled.record(endpoint, serverName) }
        )

        do {
            _ = try await engine.makeTermination(
                host: "example.com",
                to: Self.endpoint,
                plaintext: nil,
                onOutcome: { _ in }
            )
            XCTFail("Se esperaba que el fallo de emisión saliera al llamante")
        } catch is FailingMinter.Failure {
            // El interceptor lo traduce a `userspaceStackError`, que es transitorio.
        } catch {
            XCTFail("Error inesperado: \(error)")
        }

        XCTAssertEqual(dialled.count, 0)
    }
}

/// Emisor de leaves que siempre falla: cubre "la CA no está o no puede emitir para este host" sin tocar
/// el llavero.
private struct FailingMinter: LeafMinting {
    struct Failure: Error {}

    func mintLeaf(forHost host: String) async throws -> SecIdentity {
        throw Failure()
    }
}

/// Registra si se llegó a construir la pata saliente, y hacia dónde.
private final class DialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var dials: [(endpoint: IPEndpoint, serverName: String)] = []

    func record(_ endpoint: IPEndpoint, _ serverName: String) -> any RelayConnection {
        lock.lock(); dials.append((endpoint, serverName)); lock.unlock()
        return FakeRelayConnection()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return dials.count
    }
}
