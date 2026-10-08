import Foundation
import Shared
import XCTest

/// Tests del escáner de la cadena de certificados: el que sigue leyendo el stream de un servidor
/// TLS ≤ 1.2 detrás de su ServerHello.
///
/// Lo que se afirma, por orden de importancia: que lee la cadena **empiece donde empiece** respecto
/// al ServerHello (mismo record, record aparte, partida en varios), que distingue un servidor que
/// no se presenta —y por qué— de uno al que no se pudo leer, y que lo que no cabe se dice en vez
/// de perderse o de hacer crecer la memoria.
final class ServerCertificateScannerTests: XCTestCase {

    private typealias Fixtures = CertificateFixtures

    private static let twoCertificates = Fixtures.certificateMessage([Fixtures.leaf, Fixtures.intermediate])

    private static func chain(_ certificates: [ServerCertificate], isComplete: Bool = true) -> ServerCertificateScanner.Outcome {
        .found(.chain(ServerCertificateChain(certificates: certificates, isComplete: isComplete)))
    }

    private static let fullChain = chain([Fixtures.readLeaf, Fixtures.readIntermediate])

    /// Un escáner que arranca con el stream intacto detrás del ServerHello, sin nada adelantado.
    private func scanner(
        handshake: [UInt8] = [],
        stream: [UInt8] = [],
        config: ServerCertificateScanner.Config = .init()
    ) -> ServerCertificateScanner {
        var hello = ServerHelloScanner()
        let record = Fixtures.record(Fixtures.serverHelloMessage() + handshake) + stream
        guard case .found = hello.scan(Data(record)), let remainder = hello.remainder else {
            XCTFail("el fixture no es un ServerHello legible")
            return ServerCertificateScanner(resuming: .init(handshake: [], stream: []), config: config)
        }
        return ServerCertificateScanner(resuming: remainder, config: config)
    }

    // MARK: - Dónde empieza la cadena

    /// El caso normal de TLS 1.2: ServerHello y Certificate en el mismo record. La cadena ya
    /// estaba entera en lo que dejó el primer escáner, y sale sin un byte nuevo.
    func testReadsAChainThatSharedTheRecordWithTheServerHello() {
        var scanner = scanner(handshake: Self.twoCertificates)
        XCTAssertEqual(scanner.scan(Data()), Self.fullChain)
    }

    func testReadsAChainThatWasAlreadyInTheStreamInItsOwnRecord() {
        var scanner = scanner(stream: Fixtures.record(Self.twoCertificates))
        XCTAssertEqual(scanner.scan(Data()), Self.fullChain)
    }

    func testReadsAChainThatArrivesLater() {
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(Data()), .needMoreBytes)
        XCTAssertEqual(scanner.scan(Data(Fixtures.record(Self.twoCertificates))), Self.fullChain)
    }

    func testReadsAChainSplitAcrossRecords() {
        let message = Self.twoCertificates
        let cut = message.count / 2
        var scanner = scanner(handshake: Array(message[..<10]))
        XCTAssertEqual(scanner.scan(Data(Fixtures.record(Array(message[10..<cut])))), .needMoreBytes)
        XCTAssertEqual(scanner.scan(Data(Fixtures.record(Array(message[cut...])))), Self.fullChain)
    }

    func testReadsTheSameChainHoweverTheStreamIsCut() {
        let stream = Fixtures.record(Self.twoCertificates)
        for chunk in [1, 2, 3, 5, 7, 64, 500] {
            var scanner = scanner()
            var last = ServerCertificateScanner.Outcome.needMoreBytes
            var offset = 0
            while offset < stream.count {
                XCTAssertEqual(last, .needMoreBytes, "decidió antes de tiempo con trozos de \(chunk)")
                last = scanner.scan(Data(stream[offset..<min(offset + chunk, stream.count)]))
                offset += chunk
            }
            XCTAssertEqual(last, Self.fullChain, "trozos de \(chunk)")
        }
    }

    /// Lo que viene detrás del Certificate en el mismo record (ServerKeyExchange, ServerHelloDone)
    /// no estorba.
    func testWhatFollowsTheCertificateIsNotLookedAt() {
        let tail = ClientHelloFixtures.handshakeMessage(type: 12, body: [UInt8](repeating: 0x77, count: 40))
            + ClientHelloFixtures.handshakeMessage(type: 14, body: [])
        var scanner = scanner(handshake: Self.twoCertificates + tail)
        XCTAssertEqual(scanner.scan(Data()), Self.fullChain)
    }

    func testSettlesAndIgnoresWhatComesAfter() {
        var scanner = scanner(handshake: Self.twoCertificates)
        XCTAssertEqual(scanner.scan(Data()), Self.fullChain)
        XCTAssertEqual(scanner.scan(Data([0x00, 0x01, 0x02])), Self.fullChain)
    }

    func testAnEmptyCertificateListIsAnEmptyCompleteChain() {
        var scanner = scanner(handshake: Fixtures.certificateMessage([]))
        XCTAssertEqual(scanner.scan(Data()), Self.chain([]))
    }

    // MARK: - El servidor no se presenta

    /// Handshake abreviado: detrás del ServerHello va directamente el ChangeCipherSpec.
    func testAChangeCipherSpecRightAfterTheHelloIsAResumedSession() {
        var scanner = scanner(stream: Fixtures.changeCipherSpec)
        XCTAssertEqual(scanner.scan(Data()), .found(.notSent(.resumedSession)))
    }

    /// Handshake abreviado que renueva el ticket: NewSessionTicket antes del ChangeCipherSpec.
    func testANewSessionTicketRightAfterTheHelloIsAResumedSession() {
        let ticket = ClientHelloFixtures.handshakeMessage(type: 4, body: [UInt8](repeating: 0x33, count: 20))
        var scanner = scanner(handshake: ticket)
        XCTAssertEqual(scanner.scan(Data()), .found(.notSent(.resumedSession)))
    }

    func testAKeyExchangeOrHelloDoneWithoutCertificateIsACertificatelessHandshake() {
        for type: UInt8 in [12, 14] {
            var scanner = scanner(handshake: ClientHelloFixtures.handshakeMessage(type: type, body: []))
            XCTAssertEqual(scanner.scan(Data()), .found(.notSent(.noCertificateMessage)), "tipo \(type)")
        }
    }

    /// Se decide con el primer byte del mensaje: no hace falta esperar a que llegue entero.
    func testTheKindOfMessageIsDecidedFromItsFirstByte() {
        var scanner = scanner(handshake: [12])
        XCTAssertEqual(scanner.scan(Data()), .found(.notSent(.noCertificateMessage)))
    }

    // MARK: - No se pudo leer

    func testAnAlertAfterTheHelloIsReported() {
        var scanner = scanner(stream: Array(ServerHelloFixtures.alert(description: 40)))
        XCTAssertEqual(scanner.scan(Data()), .unavailable(.alert(description: 40)))
    }

    func testAnAlertInTheMiddleOfTheCertificateIsReported() {
        var scanner = scanner(handshake: Array(Self.twoCertificates.prefix(50)))
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.alert(description: 80)), .unavailable(.alert(description: 80)))
    }

    func testAnUnexpectedHandshakeMessageIsReported() {
        var scanner = scanner(handshake: ClientHelloFixtures.handshakeMessage(type: 13, body: []))
        XCTAssertEqual(scanner.scan(Data()), .unavailable(.unexpectedMessage(type: 13)))
    }

    func testARecordThatIsNotPartOfAHandshakeIsReported() {
        let applicationData = ClientHelloFixtures.record(type: 23, version: [0x03, 0x03], payload: [0x01, 0x02])
        var scanner = scanner(stream: applicationData)
        XCTAssertEqual(scanner.scan(Data()), .unavailable(.notTLSHandshake))
    }

    /// Se delata en el primer byte, sin esperar a la cabecera entera.
    func testGarbageIsReportedFromItsFirstByte() {
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(Data([0x47])), .unavailable(.notTLSHandshake))
    }

    func testAChangeCipherSpecInTheMiddleOfAMessageIsMalformed() {
        var scanner = scanner(handshake: Array(Self.twoCertificates.prefix(50)))
        XCTAssertEqual(scanner.scan(Data(Fixtures.changeCipherSpec)), .unavailable(.malformed))
    }

    func testARecordThatDeclaresMoreThanARecordCanCarryIsMalformed() {
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(Data([22, 0x03, 0x03, 0x40, 0x01])), .unavailable(.malformed))
    }

    func testAnAlertOfTheWrongLengthIsMalformed() {
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(Data([21, 0x03, 0x03, 0x00, 0x03])), .unavailable(.malformed))
    }

    func testAListLengthThatDisagreesWithTheMessageIsMalformed() {
        var body = Fixtures.certificateBody([Fixtures.leaf])
        body[2] &+= 1
        var scanner = scanner(handshake: ClientHelloFixtures.handshakeMessage(type: 11, body: body))
        XCTAssertEqual(scanner.scan(Data()), .unavailable(.malformed))
    }

    func testACertificateLengthThatOverrunsTheListIsMalformed() {
        let list = Fixtures.uint24(Fixtures.leaf.count + 50) + Fixtures.leaf
        let body = Fixtures.uint24(list.count) + list
        var scanner = scanner(handshake: ClientHelloFixtures.handshakeMessage(type: 11, body: body))
        XCTAssertEqual(scanner.scan(Data()), .unavailable(.malformed))
    }

    func testACertificateMessageTooShortForItsListLengthIsMalformed() {
        var scanner = scanner(handshake: ClientHelloFixtures.handshakeMessage(type: 11, body: [0x00, 0x00]))
        XCTAssertEqual(scanner.scan(Data()), .unavailable(.malformed))
    }

    // MARK: - Lo que no cabe se dice

    /// Un certificado que no se deja leer para la lectura: lo guardado sigue siendo el principio
    /// de la cadena, y la cadena lo dice.
    func testReadingStopsAtACertificateThatCannotBeRead() {
        let garbage = [UInt8](repeating: 0x5A, count: 40)
        var scanner = scanner(handshake: Fixtures.certificateMessage([Fixtures.leaf, garbage, Fixtures.intermediate]))
        XCTAssertEqual(scanner.scan(Data()), Self.chain([Fixtures.readLeaf], isComplete: false))
    }

    func testAnUnreadableLeafLeavesAnEmptyIncompleteChain() {
        let garbage = [UInt8](repeating: 0x5A, count: 40)
        var scanner = scanner(handshake: Fixtures.certificateMessage([garbage, Fixtures.intermediate]))
        XCTAssertEqual(scanner.scan(Data()), Self.chain([], isComplete: false))
    }

    func testCertificatesBeyondTheCountLimitLeaveTheChainIncomplete() {
        let message = Fixtures.certificateMessage([Fixtures.leaf, Fixtures.intermediate, Fixtures.intermediate])
        var limited = scanner(handshake: message, config: .init(maxCertificates: 2))
        XCTAssertEqual(limited.scan(Data()), Self.chain([Fixtures.readLeaf, Fixtures.readIntermediate], isComplete: false))

        var exact = scanner(handshake: Self.twoCertificates, config: .init(maxCertificates: 2))
        XCTAssertEqual(exact.scan(Data()), Self.fullChain)
    }

    /// Una cadena mayor que el tope no se pierde entera: se lee lo que cabe —el del servidor va
    /// el primero— **sin esperar** a que llegue el resto del mensaje.
    func testAChainOverTheByteLimitKeepsWhatFits() {
        let message = Self.twoCertificates
        let limit = Fixtures.leaf.count + 20
        var scanner = scanner(
            handshake: Array(message.prefix(4 + limit)),
            config: .init(maxChainBytes: limit)
        )
        XCTAssertEqual(scanner.scan(Data()), Self.chain([Fixtures.readLeaf], isComplete: false))
    }

    func testALeafOverTheByteLimitLeavesAnEmptyIncompleteChain() {
        var scanner = scanner(handshake: Self.twoCertificates, config: .init(maxChainBytes: 64))
        XCTAssertEqual(scanner.scan(Data()), Self.chain([], isComplete: false))
    }

    func testAByteLimitTooSmallForTheListLengthLeavesAnEmptyIncompleteChain() {
        var scanner = scanner(handshake: Self.twoCertificates, config: .init(maxChainBytes: 2))
        XCTAssertEqual(scanner.scan(Data()), Self.chain([], isComplete: false))
    }

    /// Un mensaje que declara 16 MiB se decide en cuanto llega el tope, no cuando el servidor
    /// termine de mandarlos.
    func testAHugeDeclaredMessageIsDecidedAtTheLimit() {
        let header: [UInt8] = [11, 0xFF, 0xFF, 0xFF]
        var scanner = scanner(handshake: header, config: .init(maxChainBytes: 100))
        let filler = Fixtures.record([UInt8](repeating: 0x5A, count: 60))
        XCTAssertEqual(scanner.scan(Data(filler)), .needMoreBytes)
        XCTAssertEqual(scanner.scan(Data(filler)), Self.chain([], isComplete: false))
    }

    func testNamesAreCutAtTheConfiguredLength() {
        var scanner = scanner(handshake: Fixtures.certificateMessage([Fixtures.leaf]), config: .init(maxNameLength: 6))
        XCTAssertEqual(
            scanner.scan(Data()),
            Self.chain([ServerCertificate(
                subject: CertificateName(text: "CN=www", isTruncated: true),
                issuer: CertificateName(text: "CN=Exa", isTruncated: true),
                notAfter: Fixtures.expiry
            )])
        )
    }

    // MARK: - El relevo desde el ServerHello

    func testTheServerHelloScannerHandsOverWhatFollowedTheHello() {
        var hello = ServerHelloScanner()
        let extra = Fixtures.record([0xAA, 0xBB])
        let stream = Fixtures.record(Fixtures.serverHelloMessage() + [11, 0x00]) + extra + [22, 0x03]
        guard case .found = hello.scan(Data(stream)) else { return XCTFail("no leyó el ServerHello") }
        XCTAssertEqual(hello.remainder, .init(handshake: [11, 0x00], stream: extra + [22, 0x03]))
    }

    func testThereIsNoRemainderWithoutAServerHello() {
        var pending = ServerHelloScanner()
        _ = pending.scan(Data([22, 0x03, 0x03]))
        XCTAssertNil(pending.remainder)

        var refused = ServerHelloScanner()
        _ = refused.scan(ServerHelloFixtures.alert(description: 70))
        XCTAssertNil(refused.remainder)
    }
}
