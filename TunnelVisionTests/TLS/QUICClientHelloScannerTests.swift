import Foundation
import XCTest
import Shared

/// Tests de la lectura del ClientHello de un cliente QUIC, de los payloads de sus Initial al
/// nombre. Lo ancla el ClientHello de ejemplo de la RFC 9001 § A.2 —el único que no ha escrito
/// este proyecto—, que anuncia `example.com`; lo que ese no trae (repartido en varios Initial,
/// barajado, sin nombre) se construye con los fixtures.
final class QUICClientHelloScannerTests: XCTestCase {

    private static let host = "quic.example.org"

    /// El mensaje de handshake de la RFC, sin la cabecera del frame CRYPTO (`06 00 40f1`).
    private let rfcHello = Array(QUICRFCVectors.cryptoFrame.dropFirst(4))

    private func scanner(
        maxStreamBytes: Int = 8_192, maxPendingFragments: Int = 8, maxHandshakeBytes: Int = 8_192
    ) -> QUICClientHelloScanner {
        QUICClientHelloScanner(
            streamLimits: .init(maxStreamBytes: maxStreamBytes, maxPendingFragments: maxPendingFragments),
            maxHandshakeBytes: maxHandshakeBytes
        )
    }

    private func hello(_ extensions: [ClientHelloFixtures.Extension]) -> [UInt8] {
        ClientHelloFixtures.handshakeMessage(body: ClientHelloFixtures.clientHelloBody(extensions: extensions))
    }

    private func crypto(_ message: [UInt8], _ range: Range<Int>) -> [UInt8] {
        QUICFixtures.cryptoFrame(offset: range.lowerBound, data: Array(message[range]))
    }

    private func padded(_ frames: [UInt8], to length: Int = 1_162) -> Data {
        Data(frames + [UInt8](repeating: 0, count: max(0, length - frames.count)))
    }

    // MARK: - El ClientHello de la RFC

    func testReadsTheNameOfTheRFCSampleClientHello() {
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(initialPayload: padded(QUICRFCVectors.cryptoFrame)), .found("example.com"))
        // Lo que ese ClientHello ofrece: `supported_versions` con 0304 y ALPN con «alpn».
        XCTAssertEqual(scanner.offer, ClientTLSOffer(
            versions: .listed([.tls13]),
            applicationProtocols: ["alpn"],
            omittedApplicationProtocols: 0,
            hasEncryptedClientHello: false
        ))
    }

    /// De punta a punta con 10a: el datagrama protegido de cada RFC, abierto con claves derivadas
    /// de su Connection ID, da el nombre.
    func testReadsTheNameOutOfTheProtectedRFCInitials() throws {
        for (version, bytes) in [(QUICVersion.v1, QUICRFCVectors.clientInitialV1), (.v2, QUICRFCVectors.clientInitialV2)] {
            let datagram = Data(bytes)
            let header = try QUICInitialHeader(datagram: datagram)
            let keys = try XCTUnwrap(QUICInitialKeys(
                version: header.version, clientDestinationConnectionID: header.destinationConnectionID
            ))
            let packet = try QUICInitialPacket(datagram: datagram, header: header, keys: keys, largestPacketNumber: nil)

            var scanner = scanner()
            XCTAssertEqual(scanner.scan(initialPayload: packet.frames), .found("example.com"), "\(version)")
        }
    }

    // MARK: - Repartido en varios Initial

    /// El caso que motiva la pieza: el ClientHello en tres Initial **protegidos de verdad**, que
    /// llegan desordenados y con otros frames alrededor. Cada uno se abre con las claves del
    /// primer Connection ID y el mayor número de paquete visto, como hará quien lo enganche.
    func testReadsTheNameOfAClientHelloSpreadOverThreeProtectedInitialsOutOfOrder() throws {
        let connectionID = QUICRFCVectors.destinationConnectionID
        let keys = try XCTUnwrap(QUICInitialKeys(version: .v1, clientDestinationConnectionID: Data(connectionID)))
        let payloads: [[UInt8]] = [
            [UInt8](repeating: 0, count: 300) + crypto(rfcHello, 160..<241),
            [0x01] + crypto(rfcHello, 0..<90) + [UInt8](repeating: 0, count: 200),
            QUICFixtures.ackFrame(largest: 0, delay: 40) + crypto(rfcHello, 90..<160),
        ]

        var scanner = scanner()
        var largest: UInt64?
        var outcomes: [QUICClientHelloScanner.Outcome] = []
        for (number, payload) in payloads.enumerated() {
            let datagram = Data(try QUICFixtures.clientInitial(
                keysFrom: connectionID, destinationID: connectionID,
                packetNumber: UInt64(number), packetNumberLength: 1, frames: payload
            ))
            let packet = try QUICInitialPacket(
                datagram: datagram, header: QUICInitialHeader(datagram: datagram), keys: keys, largestPacketNumber: largest
            )
            largest = packet.packetNumber
            outcomes.append(scanner.scan(initialPayload: packet.frames))
        }
        XCTAssertEqual(outcomes, [.needMoreFrames, .needMoreFrames, .found("example.com")])
    }

    /// Partido en dos Initial por **cada** punto, en los dos órdenes de llegada.
    func testReadsTheNameWhereverTheClientHelloIsSplitAndWhicheverHalfArrivesFirst() {
        for split in 1..<rfcHello.count {
            let first = padded(crypto(rfcHello, 0..<split)), second = padded(crypto(rfcHello, split..<rfcHello.count))

            var inOrder = scanner()
            XCTAssertEqual(inOrder.scan(initialPayload: first), .needMoreFrames, "corte en \(split)")
            XCTAssertEqual(inOrder.scan(initialPayload: second), .found("example.com"), "corte en \(split)")

            var backwards = scanner()
            XCTAssertEqual(backwards.scan(initialPayload: second), .needMoreFrames, "corte en \(split)")
            XCTAssertEqual(backwards.scan(initialPayload: first), .found("example.com"), "corte en \(split)")
        }
    }

    /// Un ClientHello del tamaño que les da el intercambio poscuántico no cabe en un Initial.
    func testReadsTheNameOfAClientHelloLargerThanOneInitial() {
        let message = hello([.supportedVersions, .padding(1_400), .serverName(Self.host), .applicationProtocols(["h3"])])
        XCTAssertGreaterThan(message.count, 1_200)

        var scanner = scanner()
        XCTAssertEqual(scanner.scan(initialPayload: padded(crypto(message, 0..<1_100))), .needMoreFrames)
        XCTAssertEqual(scanner.scan(initialPayload: padded(crypto(message, 1_100..<message.count))), .found(Self.host))
        XCTAssertEqual(scanner.offer?.applicationProtocols, ["h3"])
    }

    /// Lo que hace Chrome: el ClientHello troceado y barajado **dentro del mismo paquete**, con
    /// relleno entre los trozos.
    func testReadsTheNameOfAClientHelloShuffledInsideOnePacket() {
        let payload = crypto(rfcHello, 200..<241) + [0x00, 0x00]
            + crypto(rfcHello, 0..<3) + [0x01]
            + crypto(rfcHello, 120..<200)
            + crypto(rfcHello, 3..<120)
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(initialPayload: padded(payload)), .found("example.com"))
    }

    func testARetransmittedInitialDoesNotDisturbTheRead() {
        let first = padded(crypto(rfcHello, 0..<100)), second = padded(crypto(rfcHello, 100..<241))
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(initialPayload: first), .needMoreFrames)
        XCTAssertEqual(scanner.scan(initialPayload: first), .needMoreFrames)
        XCTAssertEqual(scanner.scan(initialPayload: padded(crypto(rfcHello, 40..<120))), .needMoreFrames)
        XCTAssertEqual(scanner.scan(initialPayload: second), .found("example.com"))
    }

    func testAnInitialWithoutCryptoFramesChangesNothing() {
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(initialPayload: Data()), .needMoreFrames)
        XCTAssertEqual(scanner.scan(initialPayload: padded(QUICFixtures.ackFrame(largest: 1) + [0x01])), .needMoreFrames)
        XCTAssertEqual(scanner.scan(initialPayload: padded(QUICRFCVectors.cryptoFrame)), .found("example.com"))
    }

    /// Un frame que un Initial no puede llevar corta **ese paquete**: los CRYPTO de delante
    /// cuentan, los de detrás no, y el flujo sigue con el siguiente Initial.
    func testAPacketThatStopsAtAnUnexpectedFrameKeepsItsEarlierCryptoAndTheFlowGoesOn() {
        let broken = crypto(rfcHello, 0..<100) + [0x1e] + crypto(rfcHello, 100..<241)
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(initialPayload: Data(broken)), .needMoreFrames)
        XCTAssertEqual(scanner.scan(initialPayload: padded(crypto(rfcHello, 100..<241))), .found("example.com"))
    }

    // MARK: - Sin nombre

    func testAClientHelloWithoutServerNameIsUnavailableAndStillSaysWhatItOffered() {
        var scanner = scanner()
        let message = hello([.supportedVersions, .applicationProtocols(["h3"])])
        XCTAssertEqual(
            scanner.scan(initialPayload: padded(crypto(message, 0..<message.count))),
            .unavailable(.clientHello(.noServerName))
        )
        XCTAssertEqual(scanner.offer?.versions, .listed([.tls13]))
        XCTAssertEqual(scanner.offer?.applicationProtocols, ["h3"])
    }

    /// Con ECH el nombre leído es el exterior, y la oferta lo dice: QUIC no lo esquiva.
    func testAClientHelloWithECHGivesTheOuterNameAndFlagsIt() {
        var scanner = scanner()
        let message = hello([.supportedVersions, .serverName("public.example.net"), .encryptedClientHello])
        XCTAssertEqual(scanner.scan(initialPayload: padded(crypto(message, 0..<message.count))), .found("public.example.net"))
        XCTAssertEqual(scanner.offer?.hasEncryptedClientHello, true)
    }

    func testACryptoStreamThatDoesNotStartWithAClientHelloIsUnavailable() {
        var scanner = scanner()
        let serverHello = ClientHelloFixtures.handshakeMessage(
            type: ClientHelloFixtures.serverHelloMessageType,
            body: ClientHelloFixtures.clientHelloBody(extensions: [.serverName(Self.host)])
        )
        XCTAssertEqual(
            scanner.scan(initialPayload: padded(crypto(serverHello, 0..<serverHello.count))),
            .unavailable(.clientHello(.notClientHello))
        )
        XCTAssertNil(scanner.offer)
    }

    func testAMalformedClientHelloIsUnavailable() {
        var scanner = scanner()
        // El cuerpo se queda en mitad del `random`.
        let message = ClientHelloFixtures.handshakeMessage(body: [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 10))
        XCTAssertEqual(
            scanner.scan(initialPayload: padded(crypto(message, 0..<message.count))),
            .unavailable(.clientHello(.malformed))
        )
    }

    // MARK: - Los topes

    func testAClientHelloLargerThanTheHandshakeLimitIsTooLarge() {
        var scanner = scanner(maxHandshakeBytes: 200)
        XCTAssertEqual(
            scanner.scan(initialPayload: padded(QUICRFCVectors.cryptoFrame)),
            .unavailable(.clientHello(.tooLarge))
        )
    }

    func testACryptoFrameBeyondTheStreamLimitIsUnavailable() {
        var scanner = scanner(maxStreamBytes: 240)
        XCTAssertEqual(scanner.scan(initialPayload: padded(crypto(rfcHello, 0..<100))), .needMoreFrames)
        XCTAssertEqual(
            scanner.scan(initialPayload: padded(crypto(rfcHello, 100..<241))),
            .unavailable(.cryptoStream(.streamBytes))
        )
    }

    func testMoreScatteredFragmentsThanTheLimitIsUnavailable() {
        var scanner = scanner(maxPendingFragments: 2)
        let payload = crypto(rfcHello, 10..<20) + crypto(rfcHello, 30..<40) + crypto(rfcHello, 50..<60)
        XCTAssertEqual(scanner.scan(initialPayload: padded(payload)), .unavailable(.cryptoStream(.pendingFragments)))
    }

    // MARK: - Se para cuando ya sabe

    func testTheOutcomeIsStickyOnceFound() {
        var scanner = scanner()
        XCTAssertEqual(scanner.scan(initialPayload: padded(QUICRFCVectors.cryptoFrame)), .found("example.com"))

        let other = hello([.serverName("otro.example.net")])
        XCTAssertEqual(scanner.scan(initialPayload: padded(crypto(other, 0..<other.count))), .found("example.com"))
        XCTAssertEqual(scanner.scan(initialPayload: Data([0x1e, 0xFF, 0xFF])), .found("example.com"))
        XCTAssertEqual(scanner.offer?.applicationProtocols, ["alpn"])
    }

    func testTheOutcomeIsStickyOnceUnavailable() {
        var scanner = scanner(maxPendingFragments: 0)
        XCTAssertEqual(
            scanner.scan(initialPayload: padded(crypto(rfcHello, 100..<241))),
            .unavailable(.cryptoStream(.pendingFragments))
        )
        XCTAssertEqual(
            scanner.scan(initialPayload: padded(QUICRFCVectors.cryptoFrame)),
            .unavailable(.cryptoStream(.pendingFragments))
        )
    }

    /// Dentro de un mismo payload, lo que va detrás del frame que completa el mensaje no se mira.
    func testFramesBehindTheOneThatCompletesTheMessageAreNotRead() {
        var scanner = scanner(maxStreamBytes: 300)
        let payload = QUICRFCVectors.cryptoFrame + QUICFixtures.cryptoFrame(offset: 5_000, data: [0x00])
        XCTAssertEqual(scanner.scan(initialPayload: padded(payload)), .found("example.com"))
    }
}
