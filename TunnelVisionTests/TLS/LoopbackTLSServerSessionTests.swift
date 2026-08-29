import CryptoKit
import Foundation
import Network
import Security
import Shared
import XCTest

/// Tests de la sesión de servidor TLS alimentada desde memoria.
///
/// **Lo que hace real a este test es quién habla al otro lado**: un cliente TLS de verdad
/// (Network.framework, o sea BoringSSL), con su propia evaluación de confianza, exactamente como la
/// app del dispositivo. El test hace de **túnel**: acepta la conexión del cliente por TCP plano y se
/// limita a trasegar bytes —lo que llega del cliente entra por `deliver`, lo que sale por
/// `onEncrypted` se le devuelve—, así que la sesión nunca ve un socket del cliente, solo `Data`. Es
/// la misma posición en la que estará dentro de la extensión, donde esos bytes salen del reensamblador
/// TCP en vez de un socket.
///
/// Lo que **no** cubre y sigue siendo de dispositivo: que una extensión de red pueda levantar un
/// listener de loopback bajo el sandbox de iOS.
final class LoopbackTLSServerSessionTests: XCTestCase {

    /// Caja compartida entre las colas de Network y el test.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
        var current: T { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let queue = DispatchQueue(label: "tests.tls.session")

    // MARK: - Identidad de pruebas

    /// Emite un leaf para `host` y lo convierte en `SecIdentity` importándolo al llavero, que es la
    /// única forma que tiene iOS de formar el par clave+certificado. Es lo mismo que hace
    /// `LocalCA.mintLeaf`, replicado aquí porque aquello es privado y porque el test no debe tocar los
    /// items de producción: la etiqueta lleva un UUID por test.
    private func makeIdentity(forHost host: String) async throws -> (identity: SecIdentity, rootDER: Data) {
        let ca = try CertificateAuthority.generate()
        let rootDER = await ca.exportRootCertificateDER()
        let minted = try await ca.mintLeaf(forHost: host, sans: [])

        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, minted.certificateDER as CFData))
        let leafKey = try P256.Signing.PrivateKey(derRepresentation: minted.privateKeyDER)
        var error: Unmanaged<CFError>?
        let secKey = try XCTUnwrap(SecKeyCreateWithData(
            Data(leafKey.x963Representation) as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 256,
            ] as CFDictionary,
            &error
        ))

        let label = "tests.tunnelvision.leaf.\(UUID().uuidString)"
        let keyStatus = SecItemAdd([
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecValueRef as String: secKey,
        ] as CFDictionary, nil)
        XCTAssertEqual(keyStatus, errSecSuccess, "importar la clave del leaf")
        let certStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecValueRef as String: certificate,
        ] as CFDictionary, nil)
        XCTAssertEqual(certStatus, errSecSuccess, "importar el certificado del leaf")
        addTeardownBlock {
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrLabel as String: label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ] as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess, "formar el SecIdentity")
        return (try XCTUnwrap(item as! SecIdentity?), rootDER)
    }

    // MARK: - Rig: el test hace de túnel

    /// Cliente TLS de pruebas y el trasiego que lo une a la sesión. `trust` decide si el cliente acepta
    /// la cadena: `nil` es un cliente que hace **pinning** (rechaza todo), y con raíz + host es un
    /// cliente normal que ancló nuestra CA, como haría el dispositivo con el perfil instalado.
    private struct TrustPolicy {
        var rootDER: Data?
        var verifiedHost: String?
    }

    private func makeClient(
        connectingTo port: NWEndpoint.Port,
        serverName: String,
        trust: TrustPolicy
    ) -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        let rootDER = trust.rootDER
        let verifiedHost = trust.verifiedHost
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
            guard let rootDER, let anchor = SecCertificateCreateWithData(nil, rootDER as CFData) else {
                complete(false)
                return
            }
            let secTrust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            guard SecTrustSetAnchorCertificates(secTrust, [anchor] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(secTrust, true) == errSecSuccess else {
                complete(false)
                return
            }
            if let verifiedHost,
               SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, verifiedHost as CFString)) != errSecSuccess {
                complete(false)
                return
            }
            complete(SecTrustEvaluateWithError(secTrust, nil))
        }, queue)

        return NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port),
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
    }

    /// Levanta el túnel de pruebas: un listener TCP **plano** que, al aceptar al cliente, arranca la
    /// sesión y empalma los dos sentidos. Devuelve el puerto al que el cliente debe conectarse.
    private func startTunnel(
        session: TLSServerSession,
        onReady: @escaping @Sendable () -> Void,
        onPlaintext: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (TLSServerSessionClosure) -> Void
    ) throws -> NWEndpoint.Port {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let accepted = Box<NWConnection?>(nil)
        addTeardownBlock { accepted.current?.cancel(); listener.cancel() }

        let ready = expectation(description: "tunnel listener ready")
        ready.assertForOverFulfill = false
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [queue] connection in
            accepted.mutate { $0 = connection }
            connection.start(queue: queue)
            // Lo que la sesión cifra vuelve al cliente por el mismo socket: eso es el túnel.
            session.start(
                onReady: onReady,
                onPlaintext: onPlaintext,
                onEncrypted: { data in connection.send(content: data, completion: .contentProcessed { _ in }) },
                onClose: onClose
            )
            Self.pump(connection, into: session)
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        return listener.port!
    }

    /// Bombea el socket del cliente hacia la sesión, que es lo único que hace el provider con el stream
    /// reensamblado de un flujo inspeccionado.
    private static func pump(_ connection: NWConnection, into session: TLSServerSession) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { data, _, isComplete, error in
            if let data, !data.isEmpty { session.deliver(data) }
            if error != nil { return }
            if isComplete {
                session.deliverEnd()
                return
            }
            pump(connection, into: session)
        }
    }

    // MARK: - El handshake que no se sabía si iOS permitía

    func testTrustingClientCompletesHandshakeAndPlaintextFlowsBothWays() async throws {
        let host = "inspected.example.com"
        let (identity, rootDER) = try await makeIdentity(forHost: host)
        let session = LoopbackTLSServerSession(identity: identity, queue: queue)
        addTeardownBlock { session.cancel() }

        let established = expectation(description: "handshake establecido")
        established.assertForOverFulfill = false
        let gotPlaintext = expectation(description: "plaintext del cliente")
        gotPlaintext.assertForOverFulfill = false
        let plaintext = Box<Data>(Data())

        let port = try startTunnel(
            session: session,
            onReady: { established.fulfill() },
            onPlaintext: { data in
                plaintext.mutate { $0.append(data) }
                // La sesión cifra lo que le damos: es la mitad "servidor" de la inspección.
                session.send(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8))
                gotPlaintext.fulfill()
            },
            onClose: { _ in }
        )

        let client = makeClient(
            connectingTo: port,
            serverName: host,
            trust: TrustPolicy(rootDER: rootDER, verifiedHost: host)
        )
        addTeardownBlock { client.cancel() }
        let clientReady = expectation(description: "cliente listo")
        clientReady.assertForOverFulfill = false
        client.stateUpdateHandler = { state in
            if case .ready = state { clientReady.fulfill() }
            if case .failed(let error) = state { XCTFail("el cliente no debía fallar: \(error)") }
        }
        client.start(queue: queue)
        await fulfillment(of: [clientReady, established], timeout: 15)

        let gotResponse = expectation(description: "respuesta descifrada por el cliente")
        gotResponse.assertForOverFulfill = false
        let response = Box<Data>(Data())
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            if let data, !data.isEmpty {
                response.mutate { $0.append(data) }
                gotResponse.fulfill()
            }
        }
        client.send(content: Data("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        await fulfillment(of: [gotPlaintext, gotResponse], timeout: 15)

        XCTAssertEqual(
            String(decoding: plaintext.current, as: UTF8.self),
            "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n",
            "la sesión ve en claro lo que el cliente cifró"
        )
        XCTAssertEqual(
            String(decoding: response.current, as: UTF8.self),
            "HTTP/1.1 204 No Content\r\n\r\n",
            "y lo que la sesión escribe llega cifrado y el cliente lo descifra"
        )
    }

    // MARK: - ADR 0003: el cliente que hace pinning

    func testPinningClientIsReportedAsRejectedNotAsFailure() async throws {
        let host = "pinned.example.com"
        let (identity, _) = try await makeIdentity(forHost: host)
        let session = LoopbackTLSServerSession(identity: identity, queue: queue)
        addTeardownBlock { session.cancel() }

        let closed = expectation(description: "sesión cerrada")
        closed.assertForOverFulfill = false
        let closure = Box<TLSServerSessionClosure?>(nil)

        let port = try startTunnel(
            session: session,
            onReady: { XCTFail("un cliente que hace pinning no puede establecer la sesión") },
            onPlaintext: { _ in XCTFail("no puede haber plaintext sin handshake") },
            onClose: { result in
                closure.mutate { $0 = result }
                closed.fulfill()
            }
        )

        // Cliente que hace pinning: no ancla nuestra raíz, así que rechaza la cadena entera.
        let client = makeClient(connectingTo: port, serverName: host, trust: TrustPolicy())
        addTeardownBlock { client.cancel() }
        client.start(queue: queue)
        await fulfillment(of: [closed], timeout: 15)

        XCTAssertEqual(
            closure.current,
            .rejectedByClient,
            "el rechazo del cliente es permanente (notInspectable), no un fallo transitorio"
        )
    }

    func testLeafForAnotherHostIsRejectedByAClientThatChecksTheName() async throws {
        let (identity, rootDER) = try await makeIdentity(forHost: "minted.example.com")
        let session = LoopbackTLSServerSession(identity: identity, queue: queue)
        addTeardownBlock { session.cancel() }

        let closed = expectation(description: "sesión cerrada")
        closed.assertForOverFulfill = false
        let closure = Box<TLSServerSessionClosure?>(nil)
        let port = try startTunnel(
            session: session,
            onReady: { XCTFail("el nombre no coincide: no debe establecerse") },
            onPlaintext: { _ in },
            onClose: { result in
                closure.mutate { $0 = result }
                closed.fulfill()
            }
        )

        // El cliente confía en la CA pero pide otro host: el SAN del leaf no lo cubre.
        let client = makeClient(
            connectingTo: port,
            serverName: "other.example.com",
            trust: TrustPolicy(rootDER: rootDER, verifiedHost: "other.example.com")
        )
        addTeardownBlock { client.cancel() }
        client.start(queue: queue)
        await fulfillment(of: [closed], timeout: 15)

        XCTAssertEqual(closure.current, .rejectedByClient, "un leaf para otro host se rechaza igual que un pinning")
    }

    // MARK: - Cierre

    func testClientClosingTheStreamClosesTheSession() async throws {
        let host = "closing.example.com"
        let (identity, rootDER) = try await makeIdentity(forHost: host)
        let session = LoopbackTLSServerSession(identity: identity, queue: queue)
        addTeardownBlock { session.cancel() }

        let established = expectation(description: "handshake establecido")
        established.assertForOverFulfill = false
        let closed = expectation(description: "sesión cerrada")
        closed.assertForOverFulfill = false
        let closure = Box<TLSServerSessionClosure?>(nil)

        let port = try startTunnel(
            session: session,
            onReady: { established.fulfill() },
            onPlaintext: { _ in },
            onClose: { result in
                closure.mutate { $0 = result }
                closed.fulfill()
            }
        )
        let client = makeClient(
            connectingTo: port,
            serverName: host,
            trust: TrustPolicy(rootDER: rootDER, verifiedHost: host)
        )
        client.start(queue: queue)
        await fulfillment(of: [established], timeout: 15)

        client.cancel()
        await fulfillment(of: [closed], timeout: 15)
        XCTAssertEqual(closure.current, .closed, "un cierre del cliente no es un rechazo ni un fallo")
    }

    func testCancelIsIdempotentAndSilencesTheSession() async throws {
        let (identity, _) = try await makeIdentity(forHost: "cancelled.example.com")
        let session = LoopbackTLSServerSession(identity: identity, queue: queue)

        let closed = expectation(description: "cierre notificado una sola vez")
        let closure = Box<TLSServerSessionClosure?>(nil)
        session.start(
            onReady: { XCTFail("nunca hubo cliente") },
            onPlaintext: { _ in XCTFail("nunca hubo cliente") },
            onEncrypted: { _ in },
            onClose: { result in
                closure.mutate { $0 = result }
                closed.fulfill()
            }
        )

        session.cancel()
        session.cancel()
        // Tras cancelar, empujar bytes no revive nada ni vuelve a notificar.
        session.deliver(Data([0x16, 0x03, 0x01]))
        session.send(Data("late".utf8))
        session.deliverEnd()
        session.closeSend()

        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(closure.current, .closed)
    }
}
