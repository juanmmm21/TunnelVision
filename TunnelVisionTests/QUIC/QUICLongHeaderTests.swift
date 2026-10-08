import Foundation
import XCTest
import Shared

/// Tests de la lectura de la cabecera larga de QUIC: qué se reconoce como tal y, sobre todo, qué
/// **no** — por el 443 de UDP viaja más que QUIC, y una lectura de más marcaría como cifrado un
/// flujo que no se sabe si lo va.
final class QUICLongHeaderTests: XCTestCase {

    private func version(_ bytes: [UInt8]) -> QUICVersion? {
        QUICLongHeader.version(in: Data(bytes))
    }

    // MARK: - Lo que se lee

    func testReadsVersion1FromAnInitial() {
        XCTAssertEqual(version(QUICFixtures.longHeader(version: 0x0000_0001)), .v1)
    }

    func testReadsVersion2() {
        XCTAssertEqual(version(QUICFixtures.longHeader(version: 0x6b33_43cf)), .v2)
    }

    /// Los cuatro tipos de paquete de cabecera larga van en los bits 0x30 del primer byte: la
    /// versión se lee igual en todos.
    func testReadsTheVersionWhateverTheLongPacketType() {
        for firstByte: UInt8 in [0xC0, 0xD0, 0xE0, 0xF0, 0xCF] {
            XCTAssertEqual(
                version(QUICFixtures.longHeader(version: 1, firstByte: firstByte)), .v1,
                "primer byte \(String(firstByte, radix: 16))"
            )
        }
    }

    /// Una versión que no está en el registro se entrega tal cual: es evidencia, no un error.
    func testKeepsTheRawValueOfAVersionItDoesNotKnow() {
        let draft29 = version(QUICFixtures.longHeader(version: 0xff00_001d))
        XCTAssertEqual(draft29?.rawValue, 0xff00_001d)
        XCTAssertEqual(draft29?.hasKnownPacketProtection, false)
    }

    func testReadsAHeaderWithBothConnectionIDsAtTheirLimit() {
        let id = [UInt8](repeating: 0x11, count: 20)
        XCTAssertEqual(
            version(QUICFixtures.longHeader(version: 1, destinationID: id, sourceID: id, trailing: 0)), .v1
        )
    }

    func testReadsAHeaderWithEmptyConnectionIDsAndNothingAfter() {
        XCTAssertEqual(
            version(QUICFixtures.longHeader(version: 1, destinationID: [], sourceID: [], trailing: 0)), .v1
        )
    }

    /// El datagrama llega al pipeline como un trozo de otro mayor: los índices no empiezan en 0.
    func testReadsFromASliceThatDoesNotStartAtZero() {
        let prefix = [UInt8](repeating: 0xEE, count: 28)
        let whole = Data(prefix + QUICFixtures.longHeader(version: 1))
        XCTAssertEqual(QUICLongHeader.version(in: whole[28...]), .v1)
    }

    // MARK: - Lo que no es una cabecera larga

    func testAShortHeaderHasNoVersion() {
        XCTAssertNil(version(QUICFixtures.shortHeader()))
    }

    /// Un Version Negotiation no dice qué versión habla nadie.
    func testAVersionNegotiationPacketHasNoVersion() {
        XCTAssertNil(version(QUICFixtures.longHeader(version: 0)))
    }

    /// RTP empieza por `10xxxxxx`: primer bit a 1 y el fixed bit a 0.
    func testAPayloadWithoutTheFixedBitIsNotRead() {
        XCTAssertNil(version(QUICFixtures.longHeader(version: 1, firstByte: 0x80)))
    }

    func testAnEmptyOrTooShortPayloadIsNotRead() {
        XCTAssertNil(version([]))
        XCTAssertNil(version([0xC0]))
        XCTAssertNil(version([0xC0, 0x00, 0x00, 0x00, 0x01, 0x00]))
    }

    func testAConnectionIDThatDoesNotFitIsNotRead() {
        // Dice ocho bytes de Destination ID y solo vienen tres.
        XCTAssertNil(version([0xC0, 0x00, 0x00, 0x00, 0x01, 0x08, 0xAA, 0xBB, 0xCC]))
        // El Destination cabe; la longitud del Source ya no está.
        XCTAssertNil(version([0xC0, 0x00, 0x00, 0x00, 0x01, 0x02, 0xAA, 0xBB]))
        // Y un Source que se sale.
        XCTAssertNil(version([0xC0, 0x00, 0x00, 0x00, 0x01, 0x00, 0x04, 0xAA]))
    }

    /// Las versiones 1 y 2 no admiten un Connection ID de más de 20 bytes: un paquete así no es
    /// de ellas, diga lo que diga su campo de versión.
    func testAKnownVersionWithAnOversizedConnectionIDIsNotRead() {
        let oversized = [UInt8](repeating: 0x11, count: 21)
        XCTAssertNil(version(QUICFixtures.longHeader(version: 1, destinationID: oversized)))
        XCTAssertNil(version(QUICFixtures.longHeader(version: 0x6b33_43cf, sourceID: oversized)))
    }

    /// De una versión desconocida no se sabe el tope: los invariantes dejan hasta 255.
    func testAnUnknownVersionMayCarryALongerConnectionID() {
        let long = [UInt8](repeating: 0x11, count: 40)
        XCTAssertEqual(
            version(QUICFixtures.longHeader(version: 0x0a0a_0a0a, destinationID: long))?.rawValue, 0x0a0a_0a0a
        )
    }
}

/// Tests de la versión y de la regla con la que una lectura sustituye a otra.
final class QUICVersionReadingTests: XCTestCase {

    /// Los dos valores, escritos aquí otra vez a mano desde el registro de IANA: si alguien toca
    /// la constante, esto no cambia con ella.
    func testTheNamedVersionsCarryTheirRegistryValues() {
        XCTAssertEqual(QUICVersion.v1.rawValue, 1)
        XCTAssertEqual(QUICVersion.v2.rawValue, 0x6b33_43cf)
    }

    func testOnlyTheIETFVersionsAreKnownToProtectTheirPackets() {
        XCTAssertTrue(QUICVersion.v1.hasKnownPacketProtection)
        XCTAssertTrue(QUICVersion.v2.hasKnownPacketProtection)
        // Provisionales del registro, un borrador y un valor de relleno.
        for raw: UInt32 in [0x5130_3530, 0x709a_50c4, 0x6f7d_c0fd, 0xff00_001d, 0x0a0a_0a0a] {
            XCTAssertFalse(QUICVersion(rawValue: raw).hasKnownPacketProtection, String(raw, radix: 16))
        }
    }

    private let clientV1 = QUICVersionReading(version: .v1, source: .client)
    private let clientV2 = QUICVersionReading(version: .v2, source: .client)
    private let serverV1 = QUICVersionReading(version: .v1, source: .server)
    private let serverV2 = QUICVersionReading(version: .v2, source: .server)

    func testAnyReadingReplacesNone() {
        XCTAssertTrue(clientV1.replaces(nil))
        XCTAssertTrue(serverV1.replaces(nil))
    }

    func testAServerReadingReplacesAnything() {
        XCTAssertTrue(serverV2.replaces(clientV1))
        XCTAssertTrue(serverV2.replaces(serverV1))
    }

    /// El reintento del cliente tras un Version Negotiation.
    func testAClientReadingReplacesAnEarlierClientReading() {
        XCTAssertTrue(clientV2.replaces(clientV1))
    }

    func testAClientReadingNeverReplacesWhatTheServerSaid() {
        XCTAssertFalse(clientV1.replaces(serverV2))
        XCTAssertFalse(clientV1.replaces(serverV1))
    }
}
