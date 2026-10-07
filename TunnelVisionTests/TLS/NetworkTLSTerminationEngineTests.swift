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
            makeUpstream: { endpoint, serverName, _, _ in dialled.record(endpoint, serverName) }
        )

        do {
            _ = try await engine.makeTermination(
                host: "example.com",
                to: Self.endpoint,
                plaintext: nil,
                onUpstreamTLS: nil,
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

    /// Con leaf, la pata saliente se construye hacia el destino del dispositivo, con su nombre, y
    /// **con a quién contarle lo que negocie**: es el único sitio por donde un flujo inspeccionado
    /// puede saber la versión de TLS del servidor de verdad.
    func testTheUpstreamIsBuiltWithSomewhereToReportItsTLS() async throws {
        let (identity, _) = try await makeTestTLSIdentity(forHost: "example.com")
        let dialled = DialRecorder()
        let engine = NetworkTLSTerminationEngine(
            ca: FixedMinter(identity: identity),
            queue: DispatchQueue(label: "tests.tls.engine"),
            makeUpstream: { endpoint, serverName, _, onTLSNegotiated in
                dialled.record(endpoint, serverName, onTLSNegotiated: onTLSNegotiated)
            }
        )
        let received = ReadingBox()
        let negotiated = NegotiatedTLS(
            version: .tls13, cipherSuite: TLSCipherSuite(rawValue: 0x1301),
            fromHelloRetryRequest: false, source: .upstreamConnection
        )

        let termination = try await engine.makeTermination(
            host: "example.com",
            to: Self.endpoint,
            plaintext: nil,
            onUpstreamTLS: { reading in received.set(reading) },
            onOutcome: { _ in }
        )
        addTeardownBlock { termination.cancel() }
        dialled.reportTLS(negotiated)

        XCTAssertEqual(dialled.count, 1)
        XCTAssertEqual(received.value, negotiated)
    }
}

/// Emisor que devuelve siempre el mismo leaf, ya formado.
private struct FixedMinter: LeafMinting, @unchecked Sendable {
    let identity: SecIdentity

    func mintLeaf(forHost host: String) async throws -> SecIdentity {
        identity
    }
}

private final class ReadingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NegotiatedTLS?

    func set(_ reading: NegotiatedTLS) {
        lock.lock(); stored = reading; lock.unlock()
    }

    var value: NegotiatedTLS? {
        lock.lock(); defer { lock.unlock() }
        return stored
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
    private var tlsSinks: [(@Sendable (NegotiatedTLS) -> Void)?] = []

    func record(
        _ endpoint: IPEndpoint,
        _ serverName: String,
        onTLSNegotiated: (@Sendable (NegotiatedTLS) -> Void)? = nil
    ) -> any RelayConnection {
        lock.lock()
        dials.append((endpoint, serverName))
        tlsSinks.append(onTLSNegotiated)
        lock.unlock()
        return FakeRelayConnection()
    }

    /// Simula que la última pata saliente construida terminó su handshake.
    func reportTLS(_ negotiated: NegotiatedTLS) {
        lock.lock(); let sink = tlsSinks.last ?? nil; lock.unlock()
        sink?(negotiated)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return dials.count
    }
}
