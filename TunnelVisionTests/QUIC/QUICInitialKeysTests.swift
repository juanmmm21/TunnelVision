import Foundation
import XCTest
import Shared

/// Tests de las piezas sueltas con las que se abre un Initial: el entero de longitud variable, el
/// número de paquete, las claves y la máscara de la cabecera. Los valores esperados son los que
/// imprimen las RFC 9000, 9001 y 9369 — copiados con el documento delante, no calculados aquí.
final class QUICVarintTests: XCTestCase {

    private func read(_ hex: String) -> (value: UInt64?, consumed: Int) {
        let data = Data(QUICFixtures.bytes(hex: hex))
        var index = data.startIndex
        let value = QUICVarint.read(from: data, at: &index)
        return (value, index - data.startIndex)
    }

    /// Los cinco ejemplos de la RFC 9000, Apéndice A.1.
    func testDecodesTheSamplesOfRFC9000() {
        XCTAssertEqual(read("c2197c5eff14e88c").value, 151_288_809_941_952_652)
        XCTAssertEqual(read("9d7f3e7d").value, 494_878_333)
        XCTAssertEqual(read("7bbd").value, 15_293)
        XCTAssertEqual(read("25").value, 37)
        XCTAssertEqual(read("4025").value, 37)
    }

    func testLeavesTheIndexBehindWhatItRead() {
        XCTAssertEqual(read("25ff").consumed, 1)
        XCTAssertEqual(read("7bbdff").consumed, 2)
        XCTAssertEqual(read("9d7f3e7dff").consumed, 4)
        XCTAssertEqual(read("c2197c5eff14e88cff").consumed, 8)
    }

    func testAnIntegerThatDoesNotFitIsNotReadAndTheIndexStays() {
        for hex in ["", "7b", "9d7f3e", "c2197c5eff14e8"] {
            let result = read(hex)
            XCTAssertNil(result.value, hex)
            XCTAssertEqual(result.consumed, 0, hex)
        }
    }

    func testReadsFromASliceThatDoesNotStartAtZero() {
        let whole = Data(QUICFixtures.bytes(hex: "eeeeee7bbd"))
        let slice = whole[3...]
        var index = slice.startIndex
        XCTAssertEqual(QUICVarint.read(from: slice, at: &index), 15_293)
        XCTAssertEqual(index, slice.endIndex)
    }

    func testAnIndexOutsideTheDataReadsNothing() {
        let slice = Data(QUICFixtures.bytes(hex: "ee25"))[1...]
        var before = 0
        XCTAssertNil(QUICVarint.read(from: slice, at: &before))
        var after = slice.endIndex
        XCTAssertNil(QUICVarint.read(from: slice, at: &after))
    }
}

final class QUICPacketNumberTests: XCTestCase {

    /// El ejemplo de la RFC 9000, Apéndice A.3.
    func testDecodesTheSampleOfRFC9000() {
        XCTAssertEqual(
            QUICPacketNumber.decode(truncated: 0x9b32, byteCount: 2, largestProcessed: 0xa82f_30ea),
            0xa82f_9b32
        )
    }

    /// Sin ninguno abierto antes el esperado es el 0, y un número pequeño es él mismo.
    func testTheFirstPacketOfASpaceIsTakenAsItComes() {
        for byteCount in 1...4 {
            XCTAssertEqual(QUICPacketNumber.decode(truncated: 0, byteCount: byteCount, largestProcessed: nil), 0)
            XCTAssertEqual(QUICPacketNumber.decode(truncated: 2, byteCount: byteCount, largestProcessed: nil), 2)
        }
    }

    func testANumberThatWrappedGoesToTheNextWindow() {
        XCTAssertEqual(QUICPacketNumber.decode(truncated: 0x00, byteCount: 1, largestProcessed: 0xff), 0x100)
        XCTAssertEqual(QUICPacketNumber.decode(truncated: 0x05, byteCount: 1, largestProcessed: 0x1_0004), 0x1_0005)
    }

    /// Un paquete que llega tarde, con el número de la ventana anterior.
    func testALateNumberGoesBackToThePreviousWindow() {
        XCTAssertEqual(QUICPacketNumber.decode(truncated: 0xff, byteCount: 1, largestProcessed: 0x100), 0xff)
    }

    /// Con nada abierto no hay ventana anterior a la que volver: la mitad alta no baja de cero.
    func testAHighFirstNumberDoesNotGoBelowZero() {
        XCTAssertEqual(QUICPacketNumber.decode(truncated: 0xf0, byteCount: 1, largestProcessed: nil), 0xf0)
    }

    func testRefusesWhatIsNotAPacketNumberField() {
        XCTAssertNil(QUICPacketNumber.decode(truncated: 1, byteCount: 0, largestProcessed: nil))
        XCTAssertNil(QUICPacketNumber.decode(truncated: 1, byteCount: 5, largestProcessed: nil))
        XCTAssertNil(QUICPacketNumber.decode(truncated: 0x100, byteCount: 1, largestProcessed: nil))
        XCTAssertNil(
            QUICPacketNumber.decode(truncated: 1, byteCount: 4, largestProcessed: QUICPacketNumber.maximum)
        )
    }
}

final class QUICInitialKeysTests: XCTestCase {

    private func hex(_ data: Data?) -> String? {
        data.map { $0.map { String(format: "%02x", $0) }.joined() }
    }

    private func keys(_ version: QUICVersion) -> QUICInitialKeys? {
        QUICInitialKeys(
            version: version, clientDestinationConnectionID: Data(QUICRFCVectors.destinationConnectionID)
        )
    }

    /// RFC 9001 § A.1, «The secrets for protecting client packets».
    func testDerivesTheClientKeysOfVersion1() {
        let keys = keys(.v1)
        XCTAssertEqual(keys?.version, .v1)
        XCTAssertEqual(hex(keys?.key), "1f369613dd76d5467730efcbe3b1a22d")
        XCTAssertEqual(hex(keys?.iv), "fa044b2f42a3fd3b46fb255c")
        XCTAssertEqual(hex(keys?.headerProtectionKey), "9f50449e04a0e810283a1e9933adedd2")
    }

    /// RFC 9369 § A.1: otra sal y otras etiquetas, el mismo Connection ID.
    func testDerivesTheClientKeysOfVersion2() {
        let keys = keys(.v2)
        XCTAssertEqual(keys?.version, .v2)
        XCTAssertEqual(hex(keys?.key), "8b1a0bc121284290a29e0971b5cd045d")
        XCTAssertEqual(hex(keys?.iv), "91f73e2351d8fa91660e909f")
        XCTAssertEqual(hex(keys?.headerProtectionKey), "45b95e15235d6f45a6b19cbcb0294ba9")
    }

    /// De un borrador o de una versión inventada no se conoce la sal: no se prueba con la de otra.
    func testHasNoKeysForAVersionItDoesNotKnow() {
        for raw: UInt32 in [0, 0xff00_001d, 0x1a2a_3a4a, 0x5130_3530] {
            XCTAssertNil(keys(QUICVersion(rawValue: raw)), String(raw, radix: 16))
        }
    }

    /// Un Connection ID vacío es legal tras un Retry (RFC 9001 § 5.2, nota) y da claves como
    /// cualquier otro; las de dos identificadores distintos no coinciden.
    func testAnEmptyConnectionIDStillGivesKeysOfItsOwn() {
        let empty = QUICInitialKeys(version: .v1, clientDestinationConnectionID: Data())
        XCTAssertEqual(empty?.key.count, 16)
        XCTAssertEqual(empty?.iv.count, 12)
        XCTAssertEqual(empty?.headerProtectionKey.count, 16)
        XCTAssertNotEqual(empty, keys(.v1))
    }

    // MARK: - La máscara de la cabecera

    /// RFC 9001 § A.2: `mask = AES-ECB(hp, sample)[0..4]`.
    func testMasksTheSampleOfVersion1() throws {
        let mask = try QUICHeaderProtection.mask(
            key: Data(QUICFixtures.bytes(hex: "9f50449e04a0e810283a1e9933adedd2")),
            sample: Data(QUICFixtures.bytes(hex: "d1b1c98dd7689fb8ec11d242b123dc9b"))
        )
        XCTAssertEqual(hex(mask), "437b9aec36")
    }

    /// RFC 9369 § A.2.
    func testMasksTheSampleOfVersion2() throws {
        let mask = try QUICHeaderProtection.mask(
            key: Data(QUICFixtures.bytes(hex: "45b95e15235d6f45a6b19cbcb0294ba9")),
            sample: Data(QUICFixtures.bytes(hex: "ffe67b6abcdb4298b485dd04de806071"))
        )
        XCTAssertEqual(hex(mask), "94a0c95e80")
    }

    func testMasksFromSlicesThatDoNotStartAtZero() throws {
        let key = Data(QUICFixtures.bytes(hex: "ee9f50449e04a0e810283a1e9933adedd2"))[1...]
        let sample = Data(QUICFixtures.bytes(hex: "eeeed1b1c98dd7689fb8ec11d242b123dc9b"))[2...]
        XCTAssertEqual(hex(try QUICHeaderProtection.mask(key: key, sample: sample)), "437b9aec36")
    }

    func testRefusesAKeyOrASampleOfAnotherSize() {
        let sixteen = Data(repeating: 0x11, count: 16)
        for (key, sample) in [
            (Data(repeating: 0x11, count: 15), sixteen),
            (Data(repeating: 0x11, count: 32), sixteen),
            (sixteen, Data(repeating: 0x11, count: 15)),
            (sixteen, Data(repeating: 0x11, count: 17)),
            (Data(), Data()),
        ] {
            XCTAssertThrowsError(try QUICHeaderProtection.mask(key: key, sample: sample)) { error in
                XCTAssertEqual(error as? QUICInitialError, .headerProtectionFailed)
            }
        }
    }
}
