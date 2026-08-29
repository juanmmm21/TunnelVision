import Foundation
import Shared
import XCTest

/// Tests del emparejamiento que compone la terminación TLS de un flujo: la sesión de servidor (lado
/// cliente) contra la pata saliente (lado servidor real). Las dos patas son costuras, así que aquí
/// entran dobles y lo que se afirma es lo único que pone esta pieza: **por dónde sale cada byte, en qué
/// orden, y en qué desenlace acaba cada final posible** — incluido el del ADR 0003, que es el que no se
/// puede equivocar (rechazo del cliente ⇒ `pinned`, permanente y sin reintentos).
///
/// El handshake vivo lo prueban `LoopbackTLSServerSessionTests` contra un cliente TLS de verdad; lo que
/// no se puede probar en Simulator es la pata saliente real (`NWConnection`), como en el resto del relay.
final class TLSTerminationConnectionTests: XCTestCase {

    private struct Harness {
        let connection: TLSTerminationConnection
        let session: FakeTLSServerSession
        let upstream: FakeRelayConnection
        let outcomes: TerminationRecorder
        let observed: PlaintextRecorder
        let closes: TerminationRecorder
    }

    /// Monta la terminación y la arranca, dejando registrados los tres canales que el llamante ve
    /// (ready, bytes hacia el dispositivo, cierre) más el desenlace y el plaintext observado.
    private func makeHarness(observing: Bool = true) -> Harness {
        let session = FakeTLSServerSession()
        let upstream = FakeRelayConnection()
        let outcomes = TerminationRecorder()
        let closes = TerminationRecorder()
        let observed = PlaintextRecorder()

        var sink: (@Sendable (Data, Direction) -> Void)?
        if observing {
            sink = { data, direction in observed.record(data, direction) }
        }

        let connection = TLSTerminationConnection(
            session: session,
            upstream: upstream,
            plaintext: sink,
            onOutcome: { outcome in outcomes.recordOutcome(outcome) }
        )
        connection.start(
            onReady: { closes.recordReady() },
            onReceive: { data in closes.recordReceived(data) },
            onClose: { error in closes.recordClose(error) }
        )
        return Harness(
            connection: connection,
            session: session,
            upstream: upstream,
            outcomes: outcomes,
            observed: observed,
            closes: closes
        )
    }

    /// Lleva el par hasta "hay plaintext en los dos sentidos": la salida establecida y el cliente
    /// habiendo aceptado nuestro leaf.
    private func establish(_ h: Harness) {
        h.upstream.fireReady()
        h.session.fireReady()
    }

    // MARK: - Apertura

    /// La salida existe cuando la pata saliente está establecida —para una conexión con TLS, eso
    /// incluye su handshake contra el servidor real—, no cuando se construye el par. Es la misma
    /// promesa que hace una conexión de passthrough, y es lo que deja que el relay la trate igual.
    func testReadyWaitsForTheUpstreamLeg() {
        let h = makeHarness()
        XCTAssertEqual(h.closes.readyCount, 0)

        h.session.fireReady()
        XCTAssertEqual(h.closes.readyCount, 0, "el handshake con el cliente no abre la salida")

        h.upstream.fireReady()
        XCTAssertEqual(h.closes.readyCount, 1)
    }

    // MARK: - Hacia el servidor

    /// Los records del dispositivo no se miran: van tal cual a la pila, que es la única con las claves.
    func testClientRecordsGoToTheSession() {
        let h = makeHarness()
        establish(h)

        h.connection.send(Data([0x16, 0x03, 0x01]))
        h.connection.send(Data([0x01, 0x02]))

        XCTAssertEqual(h.session.deliveredStream, Data([0x16, 0x03, 0x01, 0x01, 0x02]))
        XCTAssertTrue(h.upstream.sentPayloads.isEmpty, "un record cifrado no puede salir hacia el servidor")
    }

    /// El plaintext que la pila saca del cliente es lo que se escribe en la pata saliente, que lo vuelve
    /// a cifrar bajo confianza del sistema.
    func testClientPlaintextIsWrittenUpstream() {
        let h = makeHarness()
        establish(h)

        h.session.firePlaintext(Data("GET / HTTP/1.1\r\n".utf8))

        XCTAssertEqual(h.upstream.sentStream, Data("GET / HTTP/1.1\r\n".utf8))
    }

    /// El handshake con el cliente puede terminar antes que el TLS contra el servidor real. Perder esa
    /// primera petición sería perder justo la que explica el flujo, así que se retiene y se suelta en
    /// orden en cuanto hay salida — y una sola vez.
    func testPlaintextBeforeTheUpstreamIsHeldAndThenFlushedInOrder() {
        let h = makeHarness()
        h.session.fireReady()

        h.session.firePlaintext(Data([0x01]))
        h.session.firePlaintext(Data([0x02]))
        XCTAssertTrue(h.upstream.sentPayloads.isEmpty)

        h.upstream.fireReady()
        XCTAssertEqual(h.upstream.sentStream, Data([0x01, 0x02]))

        h.session.firePlaintext(Data([0x03]))
        XCTAssertEqual(h.upstream.sentStream, Data([0x01, 0x02, 0x03]))
    }

    /// Retener sin tope dentro de una extensión con presupuesto de memoria no es una opción: pasado el
    /// tope el flujo se cae, y se cae por la vía transitoria (no se marca nada: nadie ha rechazado nada).
    func testHeldPlaintextIsBounded() {
        let h = makeHarness()
        h.session.fireReady()

        h.session.firePlaintext(Data(repeating: 0xAA, count: TLSTerminationConnection.maximumPendingBytes + 1))

        XCTAssertEqual(h.outcomes.outcomes, [.userspaceStackError])
        XCTAssertNotNil(h.closes.closeErrors.first ?? nil, "el llamante ve un fallo, no un cierre limpio")
        XCTAssertTrue(h.session.isCancelled)
        XCTAssertTrue(h.upstream.isCancelled)
    }

    /// El FIN del dispositivo es medio cierre: la pila ve el EOF, pero el servidor puede seguir
    /// respondiendo, así que la pata saliente no se toca.
    func testCloseSendIsAHalfCloseTowardsTheSession() {
        let h = makeHarness()
        establish(h)

        h.connection.closeSend()

        XCTAssertTrue(h.session.isEndDelivered)
        XCTAssertFalse(h.upstream.isSendClosed)
    }

    // MARK: - Hacia el dispositivo

    /// Lo que la pila produce para el cliente —handshake incluido, que llega antes de que haya
    /// plaintext— son exactamente los bytes que el relay re-segmenta hacia el dispositivo.
    func testSessionRecordsGoBackToTheCaller() {
        let h = makeHarness()
        h.upstream.fireReady()

        h.session.fireEncrypted(Data([0x16, 0x03, 0x03]))

        XCTAssertEqual(h.closes.receivedStream, Data([0x16, 0x03, 0x03]))
    }

    /// Lo que entrega la pata saliente ya viene descifrado por Network: se le pasa a la sesión, que lo
    /// cifra con las claves que el cliente aceptó.
    func testServerPlaintextGoesBackThroughTheSession() {
        let h = makeHarness()
        establish(h)

        h.upstream.fireReceive(Data("HTTP/1.1 200 OK\r\n".utf8))

        XCTAssertEqual(h.session.sentStream, Data("HTTP/1.1 200 OK\r\n".utf8))
    }

    // MARK: - El contenido en claro

    /// Los dos sentidos pasan por el sumidero, y cada uno dice cuál es. Es la costura por la que el
    /// incremento siguiente persistirá el contenido descifrado.
    func testBothDirectionsAreObserved() {
        let h = makeHarness()
        establish(h)

        h.session.firePlaintext(Data("peticion".utf8))
        h.upstream.fireReceive(Data("respuesta".utf8))

        XCTAssertEqual(h.observed.entries.map(\.direction), [.outbound, .inbound])
        XCTAssertEqual(h.observed.entries.map(\.data), [Data("peticion".utf8), Data("respuesta".utf8)])
    }

    /// Sin sumidero no se copia un byte, y el trasiego sigue funcionando igual: observar es opcional,
    /// terminar no.
    func testWithoutAnObserverTheFlowStillShuttles() {
        let h = makeHarness(observing: false)
        establish(h)

        h.session.firePlaintext(Data([0x01]))
        h.upstream.fireReceive(Data([0x02]))

        XCTAssertEqual(h.upstream.sentStream, Data([0x01]))
        XCTAssertEqual(h.session.sentStream, Data([0x02]))
        XCTAssertTrue(h.observed.entries.isEmpty)
    }

    // MARK: - Desenlaces

    /// **ADR 0003.** El cliente rechaza nuestro leaf porque pinnea: no es un fallo, es su seguridad
    /// funcionando. Sale como `pinned` —que la política convierte en `notInspectable` sin reintentos— y
    /// el cierre hacia el dispositivo va limpio, porque el cliente ya mandó su alerta y sabe por qué
    /// se acaba.
    func testClientRejectionIsPinnedAndClosesCleanly() {
        let h = makeHarness()
        h.upstream.fireReady()

        h.session.fireClose(.rejectedByClient)

        XCTAssertEqual(h.outcomes.outcomes, [.pinned])
        XCTAssertEqual(h.closes.closeErrors.count, 1)
        XCTAssertNil(h.closes.closeErrors[0])
        XCTAssertTrue(h.session.isCancelled)
        XCTAssertTrue(h.upstream.isCancelled)
    }

    func testCleanCloseAfterTheHandshakeIsInspected() {
        let h = makeHarness()
        establish(h)

        h.session.fireClose(.closed)

        XCTAssertEqual(h.outcomes.outcomes, [.inspected])
    }

    /// Un cierre limpio sin haber completado el handshake no inspeccionó nada. No se sabe por qué se
    /// fue el cliente, así que va al cubo transitorio: el llamante **no** marca el flujo.
    func testCleanCloseBeforeTheHandshakeIsTransient() {
        let h = makeHarness()
        h.upstream.fireReady()

        h.session.fireClose(.closed)

        XCTAssertEqual(h.outcomes.outcomes, [.userspaceStackError])
    }

    func testSessionFailureIsTransientAndSurfacesTheError() {
        let h = makeHarness()
        establish(h)

        h.session.fireClose(.failed(TLSServerSessionError("la pila se cayó")))

        XCTAssertEqual(h.outcomes.outcomes, [.userspaceStackError])
        XCTAssertEqual(h.closes.closeErrors.first ?? nil, RelayConnectionError("la pila se cayó"))
    }

    /// Caerse antes de estar lista es, para una conexión con TLS, que el handshake contra el servidor
    /// real no se completó — que es la razón transitoria que la política distingue del resto.
    func testUpstreamFailureBeforeReadyIsAServerHandshakeFailure() {
        let h = makeHarness()

        h.upstream.fireClose(RelayConnectionError("no hay ruta"))

        XCTAssertEqual(h.outcomes.outcomes, [.serverHandshakeFailed])
        XCTAssertTrue(h.session.isCancelled)
    }

    /// Caerse a mitad, en cambio, no deshace lo que ya se inspeccionó: el flujo fue inspeccionado y el
    /// llamante no tiene nada que marcar ni por qué reintentar.
    func testUpstreamFailureAfterTheHandshakeIsStillInspected() {
        let h = makeHarness()
        establish(h)

        h.upstream.fireClose(RelayConnectionError("la red se cayó"))

        XCTAssertEqual(h.outcomes.outcomes, [.inspected])
        XCTAssertEqual(h.closes.closeErrors.first ?? nil, RelayConnectionError("la red se cayó"))
    }

    /// El servidor cierra su lado: se le traslada al cliente cerrando **nuestro** envío y ya está. Ni
    /// se derriba el par ni se reporta desenlace — lo que quede por cifrar todavía tiene que salir, y
    /// el final lo marca el cierre de la sesión, que es el único que ve los dos sentidos.
    func testServerHalfCloseIsPassedOnWithoutTearingDown() {
        let h = makeHarness()
        establish(h)

        h.upstream.fireClose(nil)

        XCTAssertTrue(h.session.isSendClosed)
        XCTAssertTrue(h.outcomes.outcomes.isEmpty)
        XCTAssertTrue(h.closes.closeErrors.isEmpty)
        XCTAssertFalse(h.session.isCancelled)
    }

    /// Cancelar es del llamante, y el llamante ya sabe cómo acaba esto: no hay desenlace que reportar
    /// (ninguno de los cuatro significa "me cancelaron") ni cierre que devolverle.
    func testCallerCancelReleasesBothLegsWithoutAnOutcome() {
        let h = makeHarness()
        establish(h)

        h.connection.cancel()
        h.connection.cancel()

        XCTAssertTrue(h.session.isCancelled)
        XCTAssertTrue(h.upstream.isCancelled)
        XCTAssertTrue(h.outcomes.outcomes.isEmpty)
        XCTAssertTrue(h.closes.closeErrors.isEmpty)
    }

    /// Las dos patas se caen a la vez más a menudo de lo que parece (una arrastra a la otra), así que
    /// el desenlace tiene que ser exactamente uno.
    func testOutcomeIsReportedOnlyOnce() {
        let h = makeHarness()
        establish(h)

        h.session.fireClose(.rejectedByClient)
        h.upstream.fireClose(RelayConnectionError("y de paso esto"))
        h.session.fireClose(.failed(TLSServerSessionError("y esto")))

        XCTAssertEqual(h.outcomes.outcomes, [.pinned])
        XCTAssertEqual(h.closes.closeErrors.count, 1)
    }

    /// Terminado el flujo, lo que siga llegando del dispositivo no tiene dónde ir: ni se entrega ni
    /// resucita nada.
    func testTrafficAfterTheEndIsDropped() {
        let h = makeHarness()
        establish(h)
        h.session.fireClose(.closed)

        h.connection.send(Data([0x01]))
        h.connection.closeSend()
        h.upstream.fireReceive(Data([0x02]))

        XCTAssertTrue(h.session.deliveredStream.isEmpty)
        XCTAssertFalse(h.session.isEndDelivered)
        XCTAssertTrue(h.session.sentStream.isEmpty)
    }
}

// MARK: - Dobles

/// Doble de `TLSServerSession`: registra lo que le entregan y expone disparadores para simular la pila
/// (handshake terminado, plaintext del cliente, records hacia el cliente y desenlace). `@unchecked
/// Sendable` con lock por lo mismo que `FakeRelayConnection`: el par la toca desde un lado y el test
/// dispara desde otro.
final class FakeTLSServerSession: TLSServerSession, @unchecked Sendable {
    private let lock = NSLock()
    private var onReady: (@Sendable () -> Void)?
    private var onPlaintext: (@Sendable (Data) -> Void)?
    private var onEncrypted: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (TLSServerSessionClosure) -> Void)?
    private var delivered: [Data] = []
    private var sent: [Data] = []
    private var endDelivered = false
    private var sendClosed = false
    private var cancelled = false

    func start(
        onReady: @escaping @Sendable () -> Void,
        onPlaintext: @escaping @Sendable (Data) -> Void,
        onEncrypted: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (TLSServerSessionClosure) -> Void
    ) {
        lock.lock()
        self.onReady = onReady
        self.onPlaintext = onPlaintext
        self.onEncrypted = onEncrypted
        self.onClose = onClose
        lock.unlock()
    }

    func deliver(_ data: Data) {
        lock.lock(); delivered.append(data); lock.unlock()
    }

    func deliverEnd() {
        lock.lock(); endDelivered = true; lock.unlock()
    }

    func send(_ plaintext: Data) {
        lock.lock(); sent.append(plaintext); lock.unlock()
    }

    func closeSend() {
        lock.lock(); sendClosed = true; lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    // MARK: Estado observable

    /// Records del cliente que llegaron a la pila, concatenados (el stream no tiene fronteras).
    var deliveredStream: Data {
        lock.lock(); defer { lock.unlock() }
        return delivered.reduce(into: Data()) { $0.append($1) }
    }

    /// Plaintext que se le mandó al cliente a través de la pila.
    var sentStream: Data {
        lock.lock(); defer { lock.unlock() }
        return sent.reduce(into: Data()) { $0.append($1) }
    }

    var isEndDelivered: Bool {
        lock.lock(); defer { lock.unlock() }
        return endDelivered
    }

    var isSendClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return sendClosed
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    // MARK: Disparadores de la pila

    func fireReady() {
        lock.lock(); let handler = onReady; lock.unlock()
        handler?()
    }

    func firePlaintext(_ data: Data) {
        lock.lock(); let handler = onPlaintext; lock.unlock()
        handler?(data)
    }

    func fireEncrypted(_ data: Data) {
        lock.lock(); let handler = onEncrypted; lock.unlock()
        handler?(data)
    }

    func fireClose(_ closure: TLSServerSessionClosure) {
        lock.lock(); let handler = onClose; lock.unlock()
        handler?(closure)
    }
}

/// Grabador de lo que la terminación le cuenta a su llamante: desenlaces, aperturas, bytes hacia el
/// dispositivo y cierres. Un solo tipo para los dos canales porque las afirmaciones son las mismas.
final class TerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOutcomes: [TLSTerminationOutcome] = []
    private var storedReady = 0
    private var storedReceived: [Data] = []
    private var storedCloses: [RelayConnectionError?] = []

    func recordOutcome(_ outcome: TLSTerminationOutcome) {
        lock.lock(); storedOutcomes.append(outcome); lock.unlock()
    }

    func recordReady() {
        lock.lock(); storedReady += 1; lock.unlock()
    }

    func recordReceived(_ data: Data) {
        lock.lock(); storedReceived.append(data); lock.unlock()
    }

    func recordClose(_ error: RelayConnectionError?) {
        lock.lock(); storedCloses.append(error); lock.unlock()
    }

    var outcomes: [TLSTerminationOutcome] {
        lock.lock(); defer { lock.unlock() }
        return storedOutcomes
    }

    var readyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storedReady
    }

    var receivedStream: Data {
        lock.lock(); defer { lock.unlock() }
        return storedReceived.reduce(into: Data()) { $0.append($1) }
    }

    var closeErrors: [RelayConnectionError?] {
        lock.lock(); defer { lock.unlock() }
        return storedCloses
    }
}

/// Grabador del contenido en claro observado, con su sentido.
final class PlaintextRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let data: Data
        let direction: Direction
    }

    private let lock = NSLock()
    private var stored: [Entry] = []

    func record(_ data: Data, _ direction: Direction) {
        lock.lock(); stored.append(Entry(data: data, direction: direction)); lock.unlock()
    }

    var entries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
