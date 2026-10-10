import Foundation
import XCTest
import Shared

/// Tests de la lectura y la apertura de un Initial del cliente. Lo que los ancla son los paquetes
/// de ejemplo de las RFC 9001 y 9369 (`QUICRFCVectors`); lo que esos dos no traen —otras
/// longitudes del número de paquete, un token, un segundo paquete en el datagrama— lo escribe
/// `QUICFixtures.clientInitial`, que protege de verdad.
final class QUICInitialPacketTests: XCTestCase {

    private let connectionID = QUICRFCVectors.destinationConnectionID

    private func keys(_ version: QUICVersion = .v1, from connectionID: [UInt8]? = nil) throws -> QUICInitialKeys {
        try XCTUnwrap(QUICInitialKeys(
            version: version, clientDestinationConnectionID: Data(connectionID ?? self.connectionID)
        ))
    }

    private func open(
        _ bytes: [UInt8], keys: QUICInitialKeys, largestPacketNumber: UInt64? = nil
    ) throws -> QUICInitialPacket {
        let datagram = Data(bytes)
        return try QUICInitialPacket(
            datagram: datagram,
            header: QUICInitialHeader(datagram: datagram),
            keys: keys,
            largestPacketNumber: largestPacketNumber
        )
    }

    private func headerError(_ bytes: [UInt8]) -> QUICInitialError? {
        do {
            _ = try QUICInitialHeader(datagram: Data(bytes))
            return nil
        } catch {
            return error as? QUICInitialError
        }
    }

    private func openError(
        _ bytes: [UInt8], keys: QUICInitialKeys, largestPacketNumber: UInt64? = nil
    ) -> QUICInitialError? {
        do {
            _ = try open(bytes, keys: keys, largestPacketNumber: largestPacketNumber)
            return nil
        } catch {
            return error as? QUICInitialError
        }
    }

    // MARK: - Los paquetes de las RFC

    func testReadsTheHeaderOfTheRFC9001ClientInitial() throws {
        let header = try QUICInitialHeader(datagram: Data(QUICRFCVectors.clientInitialV1))
        XCTAssertEqual(header.version, .v1)
        XCTAssertEqual(header.destinationConnectionID, Data(connectionID))
        XCTAssertEqual(header.sourceConnectionID, Data())
        XCTAssertEqual(header.tokenLength, 0)
        // c0 · versión · 08 + 8 bytes · 00 · 00 · 449e: el número de paquete empieza en el 18.
        XCTAssertEqual(header.packetNumberOffset, 18)
        XCTAssertEqual(header.packetLength, 1200)
    }

    /// RFC 9001 § A.2: número de paquete 2 y el frame CRYPTO seguido de relleno hasta 1162 bytes.
    func testOpensTheRFC9001ClientInitial() throws {
        let packet = try open(QUICRFCVectors.clientInitialV1, keys: keys(.v1))
        assertCarriesTheSampleClientHello(packet)
    }

    /// RFC 9369 § A.2: lo mismo con la sal, las etiquetas y los bits de tipo de la versión 2.
    func testOpensTheRFC9369ClientInitial() throws {
        let header = try QUICInitialHeader(datagram: Data(QUICRFCVectors.clientInitialV2))
        XCTAssertEqual(header.version, .v2)
        XCTAssertEqual(header.packetNumberOffset, 18)
        XCTAssertEqual(header.packetLength, 1200)

        let packet = try open(QUICRFCVectors.clientInitialV2, keys: keys(.v2))
        assertCarriesTheSampleClientHello(packet)
    }

    private func assertCarriesTheSampleClientHello(
        _ packet: QUICInitialPacket, file: StaticString = #filePath, line: UInt = #line
    ) {
        let frame = QUICRFCVectors.cryptoFrame
        XCTAssertEqual(packet.packetNumber, QUICRFCVectors.packetNumber, file: file, line: line)
        XCTAssertEqual(packet.frames.count, QUICRFCVectors.payloadLength, file: file, line: line)
        XCTAssertEqual([UInt8](packet.frames.prefix(frame.count)), frame, file: file, line: line)
        XCTAssertTrue(packet.frames.dropFirst(frame.count).allSatisfy { $0 == 0 }, file: file, line: line)
    }

    /// El datagrama llega al pipeline como un trozo de un paquete IP: los índices no empiezan en 0.
    func testOpensFromASliceThatDoesNotStartAtZero() throws {
        let whole = Data([UInt8](repeating: 0xEE, count: 28) + QUICRFCVectors.clientInitialV1)
        let datagram = whole[28...]
        let header = try QUICInitialHeader(datagram: datagram)
        XCTAssertEqual(header.packetNumberOffset, 18)
        XCTAssertEqual(header.packetLength, 1200)

        let packet = try QUICInitialPacket(
            datagram: datagram, header: header, keys: keys(.v1), largestPacketNumber: nil
        )
        assertCarriesTheSampleClientHello(packet)
    }

    // MARK: - Lo que las RFC no traen

    func testOpensEveryPacketNumberLength() throws {
        let frames = [UInt8](0..<200)
        for version in [QUICVersion.v1, .v2] {
            for length in 1...4 {
                let bytes = try QUICFixtures.clientInitial(
                    version: version, keysFrom: connectionID, destinationID: connectionID,
                    packetNumber: 7, packetNumberLength: length, frames: frames
                )
                let packet = try open(bytes, keys: keys(version))
                XCTAssertEqual(packet.packetNumber, 7, "\(version.rawValue), \(length) bytes")
                XCTAssertEqual([UInt8](packet.frames), frames, "\(version.rawValue), \(length) bytes")
                XCTAssertEqual(packet.header.packetLength, bytes.count)
            }
        }
    }

    /// El paquete más corto que se puede muestrear: número, frames y etiqueta suman veinte bytes.
    func testOpensThePacketThatBarelyHoldsASample() throws {
        for length in 1...4 {
            let frames = [UInt8](repeating: 0x01, count: 4 - length)
            let bytes = try QUICFixtures.clientInitial(
                keysFrom: connectionID, destinationID: connectionID,
                packetNumber: 0, packetNumberLength: length, frames: frames
            )
            XCTAssertEqual([UInt8](try open(bytes, keys: keys()).frames), frames, "\(length) bytes")
        }
    }

    func testReadsATokenAndASourceConnectionIDAndSkipsThem() throws {
        let token = [UInt8](repeating: 0x7E, count: 80)
        let sourceID: [UInt8] = [0xA1, 0xA2, 0xA3, 0xA4, 0xA5]
        let frames = [UInt8](repeating: 0x06, count: 64)
        let bytes = try QUICFixtures.clientInitial(
            keysFrom: connectionID, destinationID: connectionID, sourceID: sourceID, token: token,
            packetNumber: 1, packetNumberLength: 2, frames: frames
        )

        let packet = try open(bytes, keys: keys())
        XCTAssertEqual(packet.header.sourceConnectionID, Data(sourceID))
        XCTAssertEqual(packet.header.tokenLength, 80)
        // 1 + 4 + (1 + 8) + (1 + 5) + (2 + 80) + 2 de longitud.
        XCTAssertEqual(packet.header.packetNumberOffset, 104)
        XCTAssertEqual([UInt8](packet.frames), frames)
    }

    /// Tras el Initial del servidor, el cliente pasa a mandar al identificador que eligió éste,
    /// pero sigue protegiendo con las claves del primero (RFC 9001 § 5.2).
    func testTheKeysAreThoseOfTheFirstConnectionIDWhateverThePacketCarries() throws {
        let chosenByServer = [UInt8](repeating: 0x5C, count: 12)
        let frames = [UInt8](repeating: 0x06, count: 40)
        let bytes = try QUICFixtures.clientInitial(
            keysFrom: connectionID, destinationID: chosenByServer,
            packetNumber: 1, packetNumberLength: 1, frames: frames
        )

        XCTAssertEqual(try QUICInitialHeader(datagram: Data(bytes)).destinationConnectionID, Data(chosenByServer))
        XCTAssertEqual([UInt8](try open(bytes, keys: keys()).frames), frames)
        XCTAssertEqual(openError(bytes, keys: try keys(from: chosenByServer)), .authenticationFailed)
    }

    /// Un datagrama puede llevar otro paquete detrás (RFC 9000 § 12.2): la longitud dice dónde
    /// acaba éste, y lo de detrás ni se abre ni estorba.
    func testOpensOnlyItsOwnPacketWhenAnotherFollowsInTheDatagram() throws {
        let frames = [UInt8](repeating: 0x06, count: 100)
        let first = try QUICFixtures.clientInitial(
            keysFrom: connectionID, destinationID: connectionID,
            packetNumber: 0, packetNumberLength: 1, frames: frames
        )
        let second = try QUICFixtures.clientInitial(
            keysFrom: connectionID, destinationID: connectionID,
            packetNumber: 1, packetNumberLength: 1, frames: [UInt8](repeating: 0x00, count: 50)
        )
        let datagram = Data(first + second)

        let packet = try open([UInt8](datagram), keys: keys())
        XCTAssertEqual(packet.header.packetLength, first.count)
        XCTAssertEqual([UInt8](packet.frames), frames)

        // Y lo que queda es un paquete entero que se abre igual.
        let rest = datagram[packet.header.packetLength...]
        let next = try QUICInitialPacket(
            datagram: rest, header: QUICInitialHeader(datagram: rest), keys: keys(), largestPacketNumber: 0
        )
        XCTAssertEqual(next.packetNumber, 1)
        XCTAssertEqual(next.frames.count, 50)
    }

    /// El número viaja truncado y entra en el nonce: sin el mayor ya visto, uno que pasó de 255
    /// en un byte no se abre.
    func testCompletesATruncatedPacketNumberWithTheLargestSeen() throws {
        let frames = [UInt8](repeating: 0x06, count: 40)
        let bytes = try QUICFixtures.clientInitial(
            keysFrom: connectionID, destinationID: connectionID,
            packetNumber: 0x105, packetNumberLength: 1, frames: frames
        )

        let packet = try open(bytes, keys: keys(), largestPacketNumber: 0x104)
        XCTAssertEqual(packet.packetNumber, 0x105)
        XCTAssertEqual([UInt8](packet.frames), frames)
        XCTAssertEqual(openError(bytes, keys: try keys()), .authenticationFailed)
    }

    // MARK: - Lo que no se abre

    func testAPacketAlteredAnywhereDoesNotAuthenticate() throws {
        let original = try QUICFixtures.clientInitial(
            keysFrom: connectionID, destinationID: connectionID, sourceID: [0xA1, 0xA2],
            packetNumber: 3, packetNumberLength: 2, frames: [UInt8](repeating: 0x06, count: 60)
        )
        XCTAssertNil(openError(original, keys: try keys()))

        // El Source Connection ID (cabecera en claro, autenticada), el texto cifrado y la etiqueta.
        for index in [15, 16, 40, original.count - 1] {
            var altered = original
            altered[index] ^= 0x01
            XCTAssertEqual(openError(altered, keys: try keys()), .authenticationFailed, "byte \(index)")
        }
    }

    func testKeysOfAnotherConnectionDoNotOpenIt() throws {
        let other = try keys(from: [UInt8](repeating: 0x99, count: 8))
        XCTAssertEqual(openError(QUICRFCVectors.clientInitialV1, keys: other), .authenticationFailed)
    }

    func testKeysOfAnotherVersionAreRefusedBeforeTrying() throws {
        XCTAssertEqual(openError(QUICRFCVectors.clientInitialV1, keys: try keys(.v2)), .keysOfAnotherVersion)
        XCTAssertEqual(openError(QUICRFCVectors.clientInitialV2, keys: try keys(.v1)), .keysOfAnotherVersion)
    }

    /// La cabecera de un datagrama no sirve para abrir otro más corto.
    func testAHeaderDoesNotOpenADatagramShorterThanItsPacket() throws {
        let whole = Data(QUICRFCVectors.clientInitialV1)
        let header = try QUICInitialHeader(datagram: whole)
        XCTAssertThrowsError(
            try QUICInitialPacket(
                datagram: whole.prefix(1199), header: header, keys: keys(), largestPacketNumber: nil
            )
        ) { XCTAssertEqual($0 as? QUICInitialError, .truncated) }
    }

    // MARK: - Lo que no es un Initial

    func testWhatDoesNotStartWithALongHeaderIsNotRead() {
        XCTAssertEqual(headerError([]), .notALongHeader)
        XCTAssertEqual(headerError(QUICFixtures.shortHeader()), .notALongHeader)
        // Cabecera larga con el fixed bit a 0.
        XCTAssertEqual(headerError(QUICFixtures.longHeader(version: 1, firstByte: 0x80)), .notALongHeader)
        XCTAssertEqual(headerError([0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00]), .notALongHeader)
    }

    func testAVersionWhoseProtectionIsNotKnownIsNotRead() {
        for raw: UInt32 in [0, 0xff00_001d, 0x1a2a_3a4a] {
            XCTAssertEqual(
                headerError(QUICFixtures.longHeader(version: raw)),
                .unsupportedVersion(QUICVersion(rawValue: raw)),
                String(raw, radix: 16)
            )
        }
    }

    /// Los bits de tipo no van protegidos, así que los demás paquetes de cabecera larga se
    /// descartan sin tocar una clave. En la versión 1 el Initial es `00`; en la 2, `01`
    /// (RFC 9369 § 3.2), de modo que el mismo primer byte no dice lo mismo en las dos.
    func testOtherLongHeaderPacketTypesAreNotInitials() {
        for firstByte: UInt8 in [0xD0, 0xE0, 0xF0, 0xDF] {
            XCTAssertEqual(
                headerError(QUICFixtures.longHeader(version: 1, firstByte: firstByte)), .notAnInitial,
                "v1, \(String(firstByte, radix: 16))"
            )
        }
        for firstByte: UInt8 in [0xC0, 0xE0, 0xF0, 0xCF] {
            XCTAssertEqual(
                headerError(QUICFixtures.longHeader(version: 0x6b33_43cf, firstByte: firstByte)), .notAnInitial,
                "v2, \(String(firstByte, radix: 16))"
            )
        }
    }

    func testAConnectionIDOverTheLimitIsRefused() {
        let tooLong = [UInt8](repeating: 0x11, count: 21)
        XCTAssertEqual(
            headerError(QUICFixtures.longHeader(version: 1, destinationID: tooLong)), .connectionIDTooLong
        )
        XCTAssertEqual(
            headerError(QUICFixtures.longHeader(version: 1, sourceID: tooLong)), .connectionIDTooLong
        )
    }

    /// Cortado en cualquier punto de la cabecera, o con menos bytes de los que declara.
    func testATruncatedPacketIsRefused() {
        let packet = QUICRFCVectors.clientInitialV1
        for length in 1..<18 {
            XCTAssertEqual(headerError(Array(packet.prefix(length))), .truncated, "\(length) bytes")
        }
        for length in [18, 600, 1199] {
            XCTAssertEqual(headerError(Array(packet.prefix(length))), .truncated, "\(length) bytes")
        }
    }

    func testATokenLongerThanTheDatagramIsRefused() {
        // c0 · v1 · DCID vacío · SCID vacío · token de 63 bytes que no están.
        XCTAssertEqual(headerError([0xC0, 0, 0, 0, 1, 0, 0, 0x3F, 0x01, 0x02]), .truncated)
    }

    /// RFC 9001 § 5.4.2: un paquete sin sitio para la muestra se descarta.
    func testAPacketTooShortToSampleIsRefused() throws {
        // Declara 19 bytes tras la longitud, y los tiene: falta uno para muestrear.
        let short: [UInt8] = [0xC0, 0, 0, 0, 1, 0, 0, 0, 19] + [UInt8](repeating: 0x5A, count: 19)
        XCTAssertEqual(headerError(short), .tooShortToSample)
        // Con 20 la cabecera se lee; que no se abra ya es cosa de las claves.
        let enough: [UInt8] = [0xC0, 0, 0, 0, 1, 0, 0, 0, 20] + [UInt8](repeating: 0x5A, count: 20)
        XCTAssertNil(headerError(enough))
        XCTAssertEqual(openError(enough, keys: try keys(from: [])), .authenticationFailed)
    }
}
