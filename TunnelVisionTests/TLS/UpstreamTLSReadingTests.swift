import Foundation
import Network
import Security
import Shared
import XCTest

/// Tests de la lectura de lo que negocia la pata saliente de una terminación.
///
/// Tiene dos mitades. La primera es la conversión, y lo que sujeta es una **suposición sobre el
/// SDK**: que los enteros de `sec_protocol_metadata` son los del cable. La segunda es la que hace
/// real al test: un servidor TLS de verdad en loopback y una `NetworkRelayConnection` de
/// producción contra él, que es exactamente la pieza que dentro de la extensión habla con el
/// servidor real. Lo único que cambia es quién decide la confianza —aquí un ancla de pruebas, allí
/// el sistema—, y eso no toca lo que se lee.
final class UpstreamTLSReadingTests: XCTestCase {

    /// Caja compartida entre las colas de Network y el test.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
        var current: T { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let queue = DispatchQueue(label: "tests.tls.upstream")

    // MARK: - La conversión

    /// Si esto se rompe, el SDK cambió sus valores y la lectura estaría guardando otra cosa que
    /// la versión del cable: es el test que justifica no tener tabla.
    func testTheSystemsVersionsAreTheWireValues() throws {
        let tls12 = try XCTUnwrap(UpstreamTLSReading.negotiated(version: .TLSv12, cipherSuite: .AES_128_GCM_SHA256))
        let tls13 = try XCTUnwrap(UpstreamTLSReading.negotiated(version: .TLSv13, cipherSuite: .AES_128_GCM_SHA256))

        XCTAssertEqual(tls12.version, .tls12)
        XCTAssertEqual(tls13.version, .tls13)
    }

    /// Lo mismo para las suites: una de TLS 1.3 y una de 1.2, contra su código del registro de IANA.
    func testTheSystemsCipherSuitesAreTheIANACodes() throws {
        let modern = try XCTUnwrap(UpstreamTLSReading.negotiated(version: .TLSv13, cipherSuite: .AES_256_GCM_SHA384))
        let legacy = try XCTUnwrap(UpstreamTLSReading.negotiated(
            version: .TLSv12, cipherSuite: .ECDHE_RSA_WITH_AES_128_GCM_SHA256
        ))

        XCTAssertEqual(modern.cipherSuite, TLSCipherSuite(rawValue: 0x1302))
        XCTAssertEqual(legacy.cipherSuite, TLSCipherSuite(rawValue: 0xC02F))
    }

    /// La lectura dice de dónde sale, y no se hace pasar por un HelloRetryRequest: el sistema
    /// informa de un handshake terminado.
    func testTheReadingIsMarkedAsTheUpstreamConnections() throws {
        let reading = try XCTUnwrap(UpstreamTLSReading.negotiated(version: .TLSv13, cipherSuite: .AES_128_GCM_SHA256))

        XCTAssertEqual(reading.source, .upstreamConnection)
        XCTAssertFalse(reading.fromHelloRetryRequest)
    }

    /// Una versión que el SDK no nombra se guarda tal cual, como las del ServerHello.
    func testAVersionTheSDKDoesNotNameIsKeptAsGiven() throws {
        let version = try XCTUnwrap(tls_protocol_version_t(rawValue: 0x7F1C))
        let suite = try XCTUnwrap(tls_ciphersuite_t(rawValue: 0x00FF))

        let reading = try XCTUnwrap(UpstreamTLSReading.negotiated(version: version, cipherSuite: suite))

        XCTAssertEqual(reading.version, TLSProtocolVersion(rawValue: 0x7F1C))
        XCTAssertEqual(reading.cipherSuite, TLSCipherSuite(rawValue: 0x00FF))
    }

    /// Sin versión no hay lectura: unos ceros guardados serían un hallazgo inventado.
    func testNoVersionIsNoReading() throws {
        let none = try XCTUnwrap(tls_protocol_version_t(rawValue: 0))

        XCTAssertNil(UpstreamTLSReading.negotiated(version: none, cipherSuite: .AES_128_GCM_SHA256))
    }

    // MARK: - Contra un servidor TLS de verdad

    /// Levanta un servidor TLS en loopback con un leaf de pruebas y devuelve su puerto y la raíz
    /// que un cliente tiene que anclar. `maximum` deja acotar la versión que acepta, que es como
    /// se consigue un servidor que solo habla TLS 1.2.
    private func startServer(
        host: String,
        maximum: tls_protocol_version_t?
    ) async throws -> (port: NWEndpoint.Port, rootDER: Data) {
        let (identity, rootDER) = try await makeTestTLSIdentity(forHost: host)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            tls.securityProtocolOptions, try XCTUnwrap(sec_identity_create(identity))
        )
        if let maximum {
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, maximum)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let accepted = Box<[NWConnection]>([])
        addTeardownBlock { accepted.current.forEach { $0.cancel() }; listener.cancel() }

        let ready = expectation(description: "servidor TLS a la escucha")
        ready.assertForOverFulfill = false
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [queue] connection in
            accepted.mutate { $0.append(connection) }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        return (try XCTUnwrap(listener.port), rootDER)
    }

    /// La conexión de producción contra el servidor de pruebas. La confianza se ancla a la raíz
    /// del test **solo aquí**: la pata saliente de verdad no lleva bloque de verificación
    /// (`NetworkTLSTerminationEngine.upstream`), y lo que se prueba es la lectura, no la confianza.
    private func makeUpstream(
        to port: NWEndpoint.Port,
        serverName: String,
        rootDER: Data,
        onTLSNegotiated: @escaping @Sendable (NegotiatedTLS) -> Void
    ) -> NetworkRelayConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            guard let anchor = SecCertificateCreateWithData(nil, rootDER as CFData),
                  SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
                complete(false)
                return
            }
            complete(SecTrustEvaluateWithError(trust, nil))
        }, queue)
        let connection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port),
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
        return NetworkRelayConnection(
            connection: connection, queue: queue, mode: .stream, onTLSNegotiated: onTLSNegotiated
        )
    }

    /// Arranca `upstream` y devuelve, cuando está lista, lo que dijo de su TLS y en qué orden
    /// llegaron los dos avisos.
    private func readNegotiation(
        host: String,
        serverMaximum: tls_protocol_version_t?
    ) async throws -> (readings: [NegotiatedTLS], events: [String]) {
        let (port, rootDER) = try await startServer(host: host, maximum: serverMaximum)
        let readings = Box<[NegotiatedTLS]>([])
        let events = Box<[String]>([])
        let upstream = makeUpstream(to: port, serverName: host, rootDER: rootDER) { negotiated in
            readings.mutate { $0.append(negotiated) }
            events.mutate { $0.append("tls") }
        }
        addTeardownBlock { upstream.cancel() }

        let ready = expectation(description: "pata saliente lista")
        ready.assertForOverFulfill = false
        upstream.start(
            onReady: {
                events.mutate { $0.append("ready") }
                ready.fulfill()
            },
            onReceive: { _ in },
            onClose: { error in
                if let error { XCTFail("la pata saliente no debía fallar: \(error.description)") }
            }
        )
        await fulfillment(of: [ready], timeout: 15)
        return (readings.current, events.current)
    }

    func testAConnectionToATLS13ServerSaysItNegotiatedTLS13() async throws {
        let (readings, _) = try await readNegotiation(host: "modern.example.com", serverMaximum: nil)

        let reading = try XCTUnwrap(readings.first)
        XCTAssertEqual(readings.count, 1, "una lectura por conexión")
        XCTAssertEqual(reading.version, .tls13)
        // Las tres suites de TLS 1.3 que ofrece el sistema (RFC 8446 § B.4).
        XCTAssertTrue(
            [0x1301, 0x1302, 0x1303].contains(reading.cipherSuite.rawValue),
            "suite inesperada: \(String(reading.cipherSuite.rawValue, radix: 16))"
        )
        XCTAssertEqual(reading.source, .upstreamConnection)
    }

    /// El caso que le importa a una auditoría: un servidor que no pasa de TLS 1.2 se informa como
    /// 1.2, que es lo que dice el servidor y no lo máximo que ofrecíamos.
    func testAConnectionToAServerCappedAtTLS12SaysTLS12() async throws {
        let (readings, _) = try await readNegotiation(host: "legacy.example.com", serverMaximum: .TLSv12)

        let reading = try XCTUnwrap(readings.first)
        XCTAssertEqual(reading.version, .tls12)
        XCTAssertFalse(
            [0x1301, 0x1302, 0x1303].contains(reading.cipherSuite.rawValue),
            "una suite de TLS 1.3 en una conexión 1.2"
        )
        XCTAssertNotEqual(reading.cipherSuite.rawValue, 0)
    }

    /// La lectura llega antes que `onReady`: quien la apunta la tiene puesta cuando el flujo
    /// empieza a moverse.
    func testTheReadingArrivesBeforeTheConnectionIsReportedReady() async throws {
        let (_, events) = try await readNegotiation(host: "ordered.example.com", serverMaximum: nil)

        XCTAssertEqual(events, ["tls", "ready"])
    }

    /// Una conexión sin TLS —las de passthrough— no tiene nada que decir, y no dice nada.
    func testAPlainConnectionReportsNoTLS() async throws {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let accepted = Box<[NWConnection]>([])
        addTeardownBlock { accepted.current.forEach { $0.cancel() }; listener.cancel() }
        let listening = expectation(description: "servidor llano a la escucha")
        listening.assertForOverFulfill = false
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { [queue] connection in
            accepted.mutate { $0.append(connection) }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        await fulfillment(of: [listening], timeout: 5)

        let readings = Box<[NegotiatedTLS]>([])
        let upstream = NetworkRelayConnection(
            connection: NWConnection(
                to: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)), using: .tcp
            ),
            queue: queue,
            mode: .stream,
            onTLSNegotiated: { negotiated in readings.mutate { $0.append(negotiated) } }
        )
        addTeardownBlock { upstream.cancel() }
        let ready = expectation(description: "conexión llana lista")
        ready.assertForOverFulfill = false
        upstream.start(onReady: { ready.fulfill() }, onReceive: { _ in }, onClose: { _ in })
        await fulfillment(of: [ready], timeout: 15)

        XCTAssertTrue(readings.current.isEmpty)
    }
}
