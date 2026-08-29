import Foundation
import Shared
import XCTest

/// Tests del interceptor TLS. El I/O vivo —la sesión de servidor contra el cliente y la pata saliente
/// contra el servidor real— tiene los suyos (`TLSTerminationConnectionTests`,
/// `LoopbackTLSServerSessionTests`); aquí se prueba toda la **decisión**: las precondiciones que
/// fuerzan passthrough antes de tocar nada, el invariante de pinning (rechazo del cliente ⇒
/// `notInspectable`, sin reintentos) y el mapeo de los fallos. Por eso el motor se sustituye por un
/// doble guionizado.
final class TLSInterceptorTests: XCTestCase {

    private static let endpoint = IPEndpoint(
        address: IPAddress(version: .v4, bytes: [93, 184, 216, 34]),
        port: 443
    )

    // MARK: - Núcleo puro: gate (precondiciones)

    func testGateWithoutCAAbortsAsNoCA() {
        XCTAssertEqual(
            TLSInterceptionPolicy.gate(caReady: false, clientHelloSNI: "example.com"),
            .abort(.noCA)
        )
    }

    func testGateWithoutSNIAbortsAsNoSNI() {
        XCTAssertEqual(TLSInterceptionPolicy.gate(caReady: true, clientHelloSNI: nil), .abort(.noSNI))
    }

    func testGateWithEmptySNIAbortsAsNoSNI() {
        XCTAssertEqual(TLSInterceptionPolicy.gate(caReady: true, clientHelloSNI: ""), .abort(.noSNI))
    }

    func testGateWithCAAndSNIAttempts() {
        XCTAssertEqual(
            TLSInterceptionPolicy.gate(caReady: true, clientHelloSNI: "example.com"),
            .attempt(sni: "example.com")
        )
    }

    /// La CA se comprueba antes que el SNI: sin CA no importa que falte el SNI, el motivo reportado es
    /// el más fundamental (no hay con qué inspeccionar).
    func testGateChecksCABeforeSNI() {
        XCTAssertEqual(TLSInterceptionPolicy.gate(caReady: false, clientHelloSNI: nil), .abort(.noCA))
    }

    // MARK: - Núcleo puro: decide (resolución del desenlace)

    func testDecideInspected() {
        XCTAssertEqual(TLSInterceptionPolicy.decide(.inspected), .inspected)
    }

    func testDecidePinnedIsNotInspectable() {
        XCTAssertEqual(TLSInterceptionPolicy.decide(.pinned), .notInspectable)
    }

    func testDecideServerFailureIsTypedError() {
        XCTAssertEqual(TLSInterceptionPolicy.decide(.serverHandshakeFailed), .fail(.handshakeWithServerFailed))
    }

    func testDecideStackErrorIsTypedError() {
        XCTAssertEqual(TLSInterceptionPolicy.decide(.userspaceStackError), .fail(.userspaceStackError))
    }

    // MARK: - Actor: precondiciones que fuerzan passthrough (transitorio, sin marcar)

    func testOpenWithoutCAThrowsNoCAWithoutTouchingTheEngine() async {
        let engine = ScriptedTerminationEngine()
        let interceptor = TLSInterceptor(engine: engine, caReady: { false })

        await assertThrows(.noCA) {
            _ = try await interceptor.open(to: Self.endpoint, clientHelloSNI: "example.com", onResolve: { _ in })
        }
        // Sin CA no se toca la red: ni se emite un leaf ni se abre nada hacia el servidor.
        let count = await engine.callCount
        XCTAssertEqual(count, 0)
    }

    func testOpenWithoutSNIThrowsNoSNIWithoutTouchingTheEngine() async {
        let engine = ScriptedTerminationEngine()
        let interceptor = TLSInterceptor(engine: engine, caReady: { true })

        await assertThrows(.noSNI) {
            _ = try await interceptor.open(to: Self.endpoint, clientHelloSNI: nil, onResolve: { _ in })
        }
        let count = await engine.callCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - Actor: la terminación que se devuelve

    /// Con las precondiciones puestas se devuelve la terminación —que el llamante alimentará con el
    /// stream del dispositivo— y la cáscara recibió las dos cosas que determinan el resto: el host del
    /// ClientHello (el leaf que se presenta y el nombre contra el que se valida el servidor) y el
    /// destino que eligió el dispositivo.
    func testOpenReturnsTheTerminationBuiltForTheHostAndEndpoint() async throws {
        let engine = ScriptedTerminationEngine()
        let interceptor = TLSInterceptor(engine: engine, caReady: { true })

        _ = try await interceptor.open(to: Self.endpoint, clientHelloSNI: "example.com", onResolve: { _ in })

        let count = await engine.callCount
        let host = await engine.lastHost
        let endpoint = await engine.lastEndpoint
        XCTAssertEqual(count, 1)
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(endpoint, Self.endpoint)
    }

    /// Un fallo al construirla (no se pudo emitir el leaf, la pila no levantó) es transitorio: el
    /// llamante relaya el flujo intacto y **sin** marcarlo.
    func testOpenSurfacesAConstructionFailureAsAStackError() async {
        let engine = ScriptedTerminationEngine(failure: TLSInterceptError.userspaceStackError)
        let interceptor = TLSInterceptor(engine: engine, caReady: { true })

        await assertThrows(.userspaceStackError) {
            _ = try await interceptor.open(to: Self.endpoint, clientHelloSNI: "example.com", onResolve: { _ in })
        }
    }

    /// Un error que no sea de los nuestros se colapsa igual: el llamante tiene un solo tipo que entender.
    func testOpenCollapsesAnUnknownFailureIntoAStackError() async {
        let engine = ScriptedTerminationEngine(failure: RelayConnectionError("lo que sea"))
        let interceptor = TLSInterceptor(engine: engine, caReady: { true })

        await assertThrows(.userspaceStackError) {
            _ = try await interceptor.open(to: Self.endpoint, clientHelloSNI: "example.com", onResolve: { _ in })
        }
    }

    // MARK: - Actor: desenlaces del flujo terminado

    func testTrustingClientResolvesAsInspected() async throws {
        let (engine, resolutions) = try await openScripted()

        await engine.fireOutcome(.inspected)

        XCTAssertEqual(resolutions.decisions, [.inspected])
    }

    /// El invariante del ADR 0003: un cliente que rechaza nuestro leaf (pinning) ⇒ `.notInspectable`
    /// —el llamante marca el flujo y relaya intacto— y **no se reintenta**: el motor se llamó una vez
    /// y nadie vuelve a pedirle nada.
    func testPinningClientResolvesAsNotInspectableWithoutRetry() async throws {
        let (engine, resolutions) = try await openScripted()

        await engine.fireOutcome(.pinned)

        XCTAssertEqual(resolutions.decisions, [.notInspectable])
        let count = await engine.callCount
        XCTAssertEqual(count, 1)
    }

    func testServerHandshakeFailureResolvesAsATypedFailure() async throws {
        let (engine, resolutions) = try await openScripted()

        await engine.fireOutcome(.serverHandshakeFailed)

        XCTAssertEqual(resolutions.decisions, [.fail(.handshakeWithServerFailed)])
    }

    func testStackErrorResolvesAsATypedFailure() async throws {
        let (engine, resolutions) = try await openScripted()

        await engine.fireOutcome(.userspaceStackError)

        XCTAssertEqual(resolutions.decisions, [.fail(.userspaceStackError)])
    }

    // MARK: - Actor: reversibilidad de la CA en caliente

    /// `caReady` se lee en cada intento: si el usuario retira la CA mientras el túnel corre, el
    /// siguiente flujo deja de terminarse al instante (reversibilidad, spec § "Security invariants").
    func testCAReadyIsReReadOnEveryOpen() async throws {
        let engine = ScriptedTerminationEngine()
        let ready = ManualFlag(true)
        let interceptor = TLSInterceptor(engine: engine, caReady: { ready.value })

        _ = try await interceptor.open(to: Self.endpoint, clientHelloSNI: "example.com", onResolve: { _ in })

        ready.value = false
        await assertThrows(.noCA) {
            _ = try await interceptor.open(to: Self.endpoint, clientHelloSNI: "example.com", onResolve: { _ in })
        }
        // Solo el primer intento llegó a la cáscara.
        let count = await engine.callCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - Helpers

    /// Abre una terminación guionizada y devuelve las tres piezas que los tests de desenlace usan.
    private func openScripted() async throws -> (ScriptedTerminationEngine, DecisionRecorder) {
        let engine = ScriptedTerminationEngine()
        let interceptor = TLSInterceptor(engine: engine, caReady: { true })
        let resolutions = DecisionRecorder()

        _ = try await interceptor.open(
            to: Self.endpoint,
            clientHelloSNI: "example.com",
            onResolve: { decision in resolutions.record(decision) }
        )
        return (engine, resolutions)
    }

    /// Afirma que `body` lanza exactamente `expected`. Envuelve `XCTAssertThrowsError` para el mundo
    /// `async` y para castear al error tipado sin ruido en cada test.
    private func assertThrows(
        _ expected: TLSInterceptError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Se esperaba que lanzara \(expected)", file: file, line: line)
        } catch let error as TLSInterceptError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Error inesperado: \(error)", file: file, line: line)
        }
    }
}

/// Doble de `TLSTerminationEngine`: devuelve una terminación de mentira (una conexión doble), registra
/// cómo lo llamaron y guarda el canal del desenlace para que el test lo dispare cuando quiera —que es
/// justo lo que la forma nueva del motor hace posible afirmar: abrir y saber cómo acabó están separados
/// por todo el flujo—. Es un `actor` porque `makeTermination` es `async`.
private actor ScriptedTerminationEngine: TLSTerminationEngine {
    private let failure: (any Error)?
    private(set) var callCount = 0
    private(set) var lastHost: String?
    private(set) var lastEndpoint: IPEndpoint?
    private var onOutcome: (@Sendable (TLSTerminationOutcome) -> Void)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func makeTermination(
        host: String,
        to endpoint: IPEndpoint,
        plaintext: (@Sendable (Data, Direction) -> Void)?,
        onOutcome: @escaping @Sendable (TLSTerminationOutcome) -> Void
    ) async throws -> any RelayConnection {
        callCount += 1
        lastHost = host
        lastEndpoint = endpoint
        if let failure { throw failure }
        self.onOutcome = onOutcome
        return FakeRelayConnection()
    }

    /// Simula que el flujo terminó con ese desenlace.
    func fireOutcome(_ outcome: TLSTerminationOutcome) {
        onOutcome?(outcome)
    }
}

/// Grabador de las decisiones que el interceptor entrega al llamante.
private final class DecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TLSInterceptionPolicy.Decision] = []

    func record(_ decision: TLSInterceptionPolicy.Decision) {
        lock.lock(); stored.append(decision); lock.unlock()
    }

    var decisions: [TLSInterceptionPolicy.Decision] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Bandera mutable y `Sendable` para simular que la app cambia el estado "CA lista" en caliente.
private final class ManualFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        self.storage = value
    }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
