import Foundation
import XCTest
import Shared

/// Tests del estado por flujo que lee el nombre de un cliente QUIC: de los datagramas que manda,
/// tal como salen por la red, al nombre de su ClientHello.
///
/// Lo anclan **los datagramas de dos clientes de verdad** (`QUICClientCaptures`: la pila de Apple
/// y Chrome) y los paquetes de ejemplo de las RFC. Lo que esos no traen —un Retry, un Connection
/// ID que cambia, varios paquetes en un datagrama, los topes— se construye con Initial protegidos
/// de verdad por los fixtures.
final class QUICClientHelloReaderTests: XCTestCase {

    private static let host = "quic.example.org"
    private static let firstID: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
    private static let serverID: [UInt8] = [0xA1, 0xA2, 0xA3, 0xA4]
    private static let retryID: [UInt8] = [0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA]

    private func reader(
        maxInitialPackets: Int = 8,
        maxStreamBytes: Int = 8_192,
        maxPendingFragments: Int = 32,
        maxHandshakeBytes: Int = 8_192
    ) -> QUICClientHelloReader {
        QUICClientHelloReader(limits: .init(
            maxInitialPackets: maxInitialPackets,
            stream: .init(maxStreamBytes: maxStreamBytes, maxPendingFragments: maxPendingFragments),
            maxHandshakeBytes: maxHandshakeBytes
        ))
    }

    private func hello(_ extensions: [ClientHelloFixtures.Extension]) -> [UInt8] {
        ClientHelloFixtures.handshakeMessage(body: ClientHelloFixtures.clientHelloBody(extensions: extensions))
    }

    private func hello(host: String) -> [UInt8] {
        hello([.serverName(host), .supportedVersions, .applicationProtocols(["h3"])])
    }

    private func crypto(_ message: [UInt8], _ range: Range<Int>) -> [UInt8] {
        QUICFixtures.cryptoFrame(offset: range.lowerBound, data: Array(message[range]))
    }

    /// Un Initial protegido con las claves de `keysFrom`, relleno hasta un tamaño de datagrama
    /// verosímil.
    private func initial(
        _ frames: [UInt8],
        number: UInt64,
        numberLength: Int = 1,
        keysFrom: [UInt8] = QUICClientHelloReaderTests.firstID,
        destinationID: [UInt8] = QUICClientHelloReaderTests.firstID,
        version: QUICVersion = .v1,
        token: [UInt8] = [],
        paddedTo length: Int = 600
    ) throws -> Data {
        Data(try QUICFixtures.clientInitial(
            version: version, keysFrom: keysFrom, destinationID: destinationID, token: token,
            packetNumber: number, packetNumberLength: numberLength,
            frames: frames + [UInt8](repeating: 0, count: max(0, length - frames.count))
        ))
    }

    private func outcomes(
        _ reader: inout QUICClientHelloReader, _ datagrams: [Data]
    ) -> [QUICClientHelloReader.Outcome] {
        datagrams.map { reader.read(datagram: $0).outcome }
    }

    // MARK: - Clientes de verdad

    /// La pila de QUIC de Apple: el nombre sale con el segundo datagrama, y con él la oferta.
    func testReadsTheNameOfTheAppleStackCapture() {
        var reader = reader()
        let datagrams = QUICClientCaptures.appleNetworkFramework.map { Data($0) }

        let first = reader.read(datagram: datagrams[0])
        XCTAssertEqual(first.outcome, .needMoreInitials)
        XCTAssertEqual(first.opened, 1)
        XCTAssertNil(first.offer)

        let second = reader.read(datagram: datagrams[1])
        XCTAssertEqual(second.outcome, .found(QUICClientCaptures.appleHost))
        XCTAssertEqual(second.opened, 1)
        XCTAssertEqual(second.offer?.versions, .listed([.tls13]))
        XCTAssertEqual(second.offer?.applicationProtocols, ["h3"])
        XCTAssertEqual(second.offer?.hasEncryptedClientHello, false)
    }

    /// Chrome trocea el ClientHello y baraja los trozos: diez frames en el primer Initial y nueve
    /// en el segundo. Con los topes del túnel sale el nombre.
    func testReadsTheNameOfTheChromeCaptureWithTheTunnelLimits() {
        var reader = QUICClientHelloReader(limits: .tunnel)
        let datagrams = QUICClientCaptures.chrome.map { Data($0) }

        XCTAssertEqual(reader.read(datagram: datagrams[0]).outcome, .needMoreInitials)
        let second = reader.read(datagram: datagrams[1])
        XCTAssertEqual(second.outcome, .found(QUICClientCaptures.chromeHost))
        XCTAssertEqual(second.offer?.versions, .listed([.tls13]))
        XCTAssertEqual(second.offer?.applicationProtocols, ["h3"])
    }

    /// Los dos datagramas del primer vuelo llegan cambiados de orden.
    func testReadsTheNameOfTheChromeCaptureArrivingOutOfOrder() {
        var reader = QUICClientHelloReader(limits: .tunnel)
        let datagrams = QUICClientCaptures.chrome.map { Data($0) }
        XCTAssertEqual(
            outcomes(&reader, [datagrams[1], datagrams[0]]),
            [.needMoreInitials, .found(QUICClientCaptures.chromeHost)]
        )
    }

    /// Si el primer vuelo no pasó por el túnel, las retransmisiones —que Chrome trocea de otra
    /// manera cada vez— bastan: se abren con el número de paquete que traen, sin haber visto los
    /// anteriores.
    func testReadsTheNameOfTheChromeCaptureFromItsRetransmissionsAlone() {
        let datagrams = QUICClientCaptures.chrome.map { Data($0) }
        for pair in [[2, 3], [3, 2], [3, 4], [4, 3]] {
            var reader = QUICClientHelloReader(limits: .tunnel)
            XCTAssertEqual(
                outcomes(&reader, pair.map { datagrams[$0] }),
                [.needMoreInitials, .found(QUICClientCaptures.chromeHost)],
                "datagramas \(pair)"
            )
        }
    }

    /// La captura entera, retransmisiones incluidas: decidido con el segundo datagrama, lo demás
    /// ni se abre.
    func testWholeCapturesSettleOnTheSecondDatagramAndOpenNothingAfterwards() {
        let captures = [
            (QUICClientCaptures.appleNetworkFramework, QUICClientCaptures.appleHost),
            (QUICClientCaptures.chrome, QUICClientCaptures.chromeHost),
        ]
        for (capture, host) in captures {
            var reader = QUICClientHelloReader(limits: .tunnel)
            let readings = capture.map { reader.read(datagram: Data($0)) }
            XCTAssertEqual(readings.map(\.opened).prefix(2), [1, 1], host)
            XCTAssertTrue(readings.dropFirst(2).allSatisfy { $0.opened == 0 && $0.notOpened == 0 }, host)
            XCTAssertTrue(readings.dropFirst().allSatisfy { $0.outcome == .found(host) }, host)
        }
    }

    /// Los topes del túnel, con nombre y contra lo medido: el mayor ClientHello capturado cabe
    /// cuatro veces, y los dos Initial que hacen falta, cuatro veces también.
    func testTheTunnelLimitsLeaveRoomOverWhatRealClientsSend() throws {
        let limits = QUICClientHelloReader.Limits.tunnel
        XCTAssertEqual(limits.maxInitialPackets, 8)
        XCTAssertEqual(limits.stream, QUICCryptoStream.Limits(maxStreamBytes: 8_192, maxPendingFragments: 32))
        XCTAssertEqual(limits.maxHandshakeBytes, 8_192)

        var largestHello = 0
        var mostFramesInAPacket = 0
        for capture in [QUICClientCaptures.appleNetworkFramework, QUICClientCaptures.chrome] {
            let first = Data(capture[0])
            let keys = try XCTUnwrap(QUICInitialKeys(
                version: .v1, clientDestinationConnectionID: try QUICInitialHeader(datagram: first).destinationConnectionID
            ))
            for bytes in capture {
                let datagram = Data(bytes)
                let packet = try QUICInitialPacket(
                    datagram: datagram, header: try QUICInitialHeader(datagram: datagram), keys: keys, largestPacketNumber: nil
                )
                let frames = QUICInitialFrames(payload: packet.frames).crypto
                mostFramesInAPacket = max(mostFramesInAPacket, frames.count)
                largestHello = max(largestHello, frames.map { Int($0.offset) + $0.data.count }.max() ?? 0)
            }
        }
        XCTAssertEqual(largestHello, 1_951)
        XCTAssertEqual(mostFramesInAPacket, 11)
        XCTAssertGreaterThanOrEqual(limits.stream.maxStreamBytes, 4 * largestHello)
        XCTAssertGreaterThanOrEqual(limits.maxHandshakeBytes, 4 * largestHello)
        XCTAssertGreaterThanOrEqual(limits.stream.maxPendingFragments, 2 * mostFramesInAPacket)
    }

    // MARK: - Los paquetes de las RFC

    func testReadsTheNameOfTheRFCSampleInitialsOfBothVersions() {
        for bytes in [QUICRFCVectors.clientInitialV1, QUICRFCVectors.clientInitialV2] {
            var reader = reader()
            let reading = reader.read(datagram: Data(bytes))
            XCTAssertEqual(reading.outcome, .found("example.com"))
            XCTAssertEqual(reading.opened, 1)
            XCTAssertEqual(reading.offer?.applicationProtocols, ["alpn"])
        }
    }

    // MARK: - Qué claves y qué número de paquete

    /// Cuando el servidor contesta, el cliente pasa a dirigirse al identificador que éste eligió
    /// y **sigue con las claves del primero**: no es un reinicio.
    func testALaterInitialAddressedToTheServersIDStillOpensWithTheFirstKeys() throws {
        let message = hello(host: Self.host)
        var reader = reader()

        let first = reader.read(datagram: try initial(crypto(message, 0..<40), number: 0))
        XCTAssertEqual(first.outcome, .needMoreInitials)

        let second = reader.read(datagram: try initial(
            crypto(message, 40..<message.count), number: 1, destinationID: Self.serverID
        ))
        XCTAssertEqual(second.outcome, .found(Self.host))
        XCTAssertEqual(second.opened, 1)
        XCTAssertFalse(second.restarted)
    }

    /// Tras un Retry el cliente vuelve a empezar con el identificador que le dio el servidor, y
    /// las claves salen de ése. Lo recompuesto antes no se mezcla con lo de después.
    func testAfterARetryTheReadStartsOverWithTheKeysOfTheNewID() throws {
        let before = hello(host: "before-retry.example.org")
        let after = hello(host: Self.host)
        var reader = reader()

        XCTAssertEqual(
            reader.read(datagram: try initial(crypto(before, 0..<60), number: 0)).outcome, .needMoreInitials
        )

        let retried = reader.read(datagram: try initial(
            crypto(after, 0..<60), number: 1, keysFrom: Self.retryID, destinationID: Self.retryID,
            token: [UInt8](repeating: 0x7E, count: 24)
        ))
        XCTAssertEqual(retried.outcome, .needMoreInitials)
        XCTAssertEqual(retried.opened, 1)
        XCTAssertTrue(retried.restarted)

        let last = reader.read(datagram: try initial(
            crypto(after, 60..<after.count), number: 2, keysFrom: Self.retryID, destinationID: Self.retryID
        ))
        XCTAssertEqual(last.outcome, .found(Self.host))
        XCTAssertFalse(last.restarted)
    }

    /// Un paquete que no autentica —alterado por el camino— se cuenta y no estropea la lectura.
    func testAnInitialThatDoesNotAuthenticateIsCountedAndTheReadGoesOn() throws {
        let message = hello(host: Self.host)
        var reader = reader()
        XCTAssertEqual(
            reader.read(datagram: try initial(crypto(message, 0..<40), number: 0)).outcome, .needMoreInitials
        )

        var corrupted = try initial(crypto(message, 40..<message.count), number: 1)
        corrupted[corrupted.count - 1] ^= 0xFF
        let failed = reader.read(datagram: corrupted)
        XCTAssertEqual(failed.outcome, .needMoreInitials)
        XCTAssertEqual(failed.opened, 0)
        XCTAssertEqual(failed.notOpened, 1)
        XCTAssertFalse(failed.restarted)

        let good = reader.read(datagram: try initial(crypto(message, 40..<message.count), number: 2))
        XCTAssertEqual(good.outcome, .found(Self.host))
    }

    /// El primer paquete de un flujo tampoco tiene por qué abrirse: sin claves que valgan no hay
    /// lectura, y el siguiente se prueba con las suyas.
    func testAFirstInitialThatDoesNotOpenLeavesTheNextOneReadable() throws {
        let message = hello(host: Self.host)
        var reader = reader()

        var corrupted = try initial(crypto(message, 0..<message.count), number: 0)
        corrupted[corrupted.count - 1] ^= 0xFF
        let failed = reader.read(datagram: corrupted)
        XCTAssertEqual(failed.notOpened, 1)
        XCTAssertFalse(failed.restarted)

        let good = reader.read(datagram: try initial(crypto(message, 0..<message.count), number: 1))
        XCTAssertEqual(good.outcome, .found(Self.host))
        XCTAssertFalse(good.restarted)
    }

    /// El número de paquete viaja truncado y se completa contra el mayor ya abierto: sin
    /// llevarlo, un número de dos bytes escrito en uno daría otro nonce y no abriría.
    func testThePacketNumberIsCompletedAgainstTheLargestOpened() throws {
        let message = hello(host: Self.host)
        var reader = reader()
        XCTAssertEqual(
            reader.read(datagram: try initial(crypto(message, 0..<40), number: 0x1234, numberLength: 2)).outcome,
            .needMoreInitials
        )

        // 0x1235 escrito en un byte: `35`.
        let truncated = Data(try QUICFixtures.clientInitial(
            keysFrom: Self.firstID, destinationID: Self.firstID,
            packetNumber: 0x1235, packetNumberLength: 1,
            frames: crypto(message, 40..<message.count) + [UInt8](repeating: 0, count: 300)
        ))
        XCTAssertEqual(reader.read(datagram: truncated).outcome, .found(Self.host))
    }

    // MARK: - Varios paquetes en un datagrama

    func testTwoInitialsCoalescedInOneDatagramAreBothRead() throws {
        let message = hello(host: Self.host)
        var reader = reader()
        let datagram = try initial(crypto(message, 0..<50), number: 0, paddedTo: 200)
            + (try initial(crypto(message, 50..<message.count), number: 1, paddedTo: 200))

        let reading = reader.read(datagram: datagram)
        XCTAssertEqual(reading.outcome, .found(Self.host))
        XCTAssertEqual(reading.opened, 2)
    }

    /// Detrás del Initial va otro tipo de paquete —un 0-RTT, lo habitual al reanudar—: el walk
    /// se para ahí y lo leído vale.
    func testWhatFollowsAnInitialInTheDatagramIsNotRead() throws {
        let message = hello(host: Self.host)
        var reader = reader()
        let zeroRTT = Data(QUICFixtures.longHeader(version: 1, firstByte: 0xD0, trailing: 80))

        let reading = reader.read(datagram: try initial(crypto(message, 0..<message.count), number: 0) + zeroRTT)
        XCTAssertEqual(reading.outcome, .found(Self.host))
        XCTAssertEqual(reading.opened, 1)
        XCTAssertEqual(reading.notOpened, 0)
    }

    /// El payload llega como un slice de un datagrama IP: los índices no empiezan en cero.
    func testReadsADatagramThatIsASliceOfALargerBuffer() throws {
        let message = hello(host: Self.host)
        var reader = reader()
        let buffer = Data([0xDE, 0xAD, 0xBE, 0xEF]) + (try initial(crypto(message, 0..<message.count), number: 0))
        XCTAssertEqual(reader.read(datagram: buffer.dropFirst(4)).outcome, .found(Self.host))
    }

    // MARK: - Lo que no es un Initial

    /// Cabeceras largas de otro tipo, otra versión, cabecera corta, nada: no se intenta abrir
    /// nada y no gastan del cupo de Initial del flujo.
    func testDatagramsThatAreNotAClientInitialAreNotAttempted() throws {
        let message = hello(host: Self.host)
        var reader = reader(maxInitialPackets: 1)
        let notInitials: [Data] = [
            Data(QUICFixtures.longHeader(version: 1, firstByte: 0xE0, trailing: 80)),   // Handshake
            Data(QUICFixtures.longHeader(version: 1, firstByte: 0xD0, trailing: 80)),   // 0-RTT
            Data(QUICFixtures.longHeader(version: 0xff00_001d, trailing: 80)),          // otra versión
            Data(QUICFixtures.longHeader(version: 0, trailing: 20)),                    // Version Negotiation
            Data(QUICFixtures.shortHeader()),
            Data(),
        ]
        for datagram in notInitials {
            let reading = reader.read(datagram: datagram)
            XCTAssertEqual(reading.outcome, .needMoreInitials)
            XCTAssertFalse(reading.attemptedAnInitial)
        }
        // El cupo era de uno y sigue entero.
        XCTAssertEqual(
            reader.read(datagram: try initial(crypto(message, 0..<message.count), number: 0)).outcome,
            .found(Self.host)
        )
    }

    // MARK: - Desenlaces sin nombre

    func testAClientHelloWithoutServerNameIsUnavailableAndStillCarriesTheOffer() throws {
        let message = hello([.supportedVersions, .applicationProtocols(["h3"])])
        var reader = reader()
        let reading = reader.read(datagram: try initial(crypto(message, 0..<message.count), number: 0))
        XCTAssertEqual(reading.outcome, .unavailable(.clientHello(.noServerName)))
        XCTAssertEqual(reading.offer?.applicationProtocols, ["h3"])
    }

    func testAClientHelloWithECHGivesTheOuterNameAndTheOfferSaysSo() throws {
        let message = hello([.serverName("public.example.net"), .supportedVersions, .encryptedClientHello])
        var reader = reader()
        let reading = reader.read(datagram: try initial(crypto(message, 0..<message.count), number: 0))
        XCTAssertEqual(reading.outcome, .found("public.example.net"))
        XCTAssertEqual(reading.offer?.hasEncryptedClientHello, true)
    }

    func testACryptoStreamThatIsNotAClientHelloIsUnavailable() throws {
        let message = ClientHelloFixtures.handshakeMessage(
            type: ClientHelloFixtures.serverHelloMessageType, body: [UInt8](repeating: 0, count: 40)
        )
        var reader = reader()
        let reading = reader.read(datagram: try initial(crypto(message, 0..<message.count), number: 0))
        XCTAssertEqual(reading.outcome, .unavailable(.clientHello(.notClientHello)))
        XCTAssertNil(reading.offer)
    }

    // MARK: - Topes

    /// El cupo de Initial se agota **con el paquete que lo agota**, sin esperar al siguiente.
    func testTheReadIsGivenUpOnThePacketThatExhaustsTheInitialBudget() throws {
        let message = hello(host: Self.host)
        var reader = reader(maxInitialPackets: 2)
        XCTAssertEqual(
            outcomes(&reader, [
                try initial(crypto(message, 0..<20), number: 0),
                try initial(crypto(message, 20..<40), number: 1),
                try initial(crypto(message, 40..<message.count), number: 2),
            ]),
            [.needMoreInitials, .unavailable(.initialsExhausted), .unavailable(.initialsExhausted)]
        )
    }

    /// El paquete que completa el mensaje vale aunque sea el último del cupo.
    func testTheLastPacketOfTheBudgetStillNamesTheFlow() throws {
        let message = hello(host: Self.host)
        var reader = reader(maxInitialPackets: 2)
        XCTAssertEqual(
            outcomes(&reader, [
                try initial(crypto(message, 0..<20), number: 0),
                try initial(crypto(message, 20..<message.count), number: 1),
            ]),
            [.needMoreInitials, .found(Self.host)]
        )
    }

    /// Los que no se abren también gastan: si no, un flujo de paquetes que no autentican tendría
    /// al túnel derivando claves y probando el AEAD sin fin.
    func testPacketsThatDoNotOpenSpendTheBudgetToo() throws {
        let message = hello(host: Self.host)
        var reader = reader(maxInitialPackets: 3)
        var corrupted = try initial(crypto(message, 0..<message.count), number: 0)
        corrupted[corrupted.count - 1] ^= 0xFF

        XCTAssertEqual(
            outcomes(&reader, [corrupted, corrupted, corrupted]),
            [.needMoreInitials, .needMoreInitials, .unavailable(.initialsExhausted)]
        )
    }

    /// El cupo se cuenta por paquete, no por datagrama.
    func testTheBudgetCountsCoalescedPacketsOneByOne() throws {
        let message = hello(host: Self.host)
        var reader = reader(maxInitialPackets: 2)
        let datagram = try initial(crypto(message, 0..<10), number: 0, paddedTo: 100)
            + (try initial(crypto(message, 10..<20), number: 1, paddedTo: 100))
            + (try initial(crypto(message, 20..<message.count), number: 2, paddedTo: 100))

        let reading = reader.read(datagram: datagram)
        XCTAssertEqual(reading.outcome, .unavailable(.initialsExhausted))
        XCTAssertEqual(reading.opened, 2)
    }

    func testTheStreamAndHandshakeLimitsReachTheScanner() throws {
        let message = hello(host: Self.host)

        var short = reader(maxStreamBytes: 30)
        XCTAssertEqual(
            short.read(datagram: try initial(crypto(message, 0..<message.count), number: 0)).outcome,
            .unavailable(.cryptoStream(.streamBytes))
        )

        var scattered = reader(maxPendingFragments: 1)
        XCTAssertEqual(
            scattered.read(datagram: try initial(crypto(message, 10..<20) + crypto(message, 30..<40), number: 0)).outcome,
            .unavailable(.cryptoStream(.pendingFragments))
        )

        var small = reader(maxHandshakeBytes: 30)
        XCTAssertEqual(
            small.read(datagram: try initial(crypto(message, 0..<message.count), number: 0)).outcome,
            .unavailable(.clientHello(.tooLarge))
        )
    }

    // MARK: - Se queda quieto

    func testAfterSettlingNothingElseIsOpened() throws {
        let message = hello(host: Self.host)
        let other = hello(host: "other.example.org")
        var reader = reader()
        XCTAssertEqual(
            reader.read(datagram: try initial(crypto(message, 0..<message.count), number: 0)).outcome,
            .found(Self.host)
        )

        // Ni otro ClientHello con las mismas claves, ni uno con las de otro identificador.
        let later = [
            try initial(crypto(other, 0..<other.count), number: 1),
            try initial(crypto(other, 0..<other.count), number: 0, keysFrom: Self.retryID, destinationID: Self.retryID),
        ]
        for datagram in later {
            let reading = reader.read(datagram: datagram)
            XCTAssertEqual(reading.outcome, .found(Self.host))
            XCTAssertFalse(reading.attemptedAnInitial)
            XCTAssertFalse(reading.restarted)
            XCTAssertNil(reading.offer)
        }
    }

    // MARK: - Coste

    /// Lo que cuesta leerle el nombre a un flujo: derivar las claves, abrir los dos Initial de
    /// Chrome —el caso más troceado que se ha capturado— y recomponer su ClientHello.
    func testCostOfReadingTheNameOfAChromeFlow() {
        let datagrams = QUICClientCaptures.chrome.prefix(2).map { Data($0) }
        measure {
            for _ in 0..<100 {
                var reader = QUICClientHelloReader(limits: .tunnel)
                for datagram in datagrams {
                    _ = reader.read(datagram: datagram)
                }
            }
        }
    }
}
