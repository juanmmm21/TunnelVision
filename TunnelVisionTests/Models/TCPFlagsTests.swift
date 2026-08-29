import XCTest
@testable import Shared

final class TCPFlagsTests: XCTestCase {
    func testRawBitPositions() {
        XCTAssertEqual(TCPFlags.fin.rawValue, 0b000001)
        XCTAssertEqual(TCPFlags.syn.rawValue, 0b000010)
        XCTAssertEqual(TCPFlags.rst.rawValue, 0b000100)
        XCTAssertEqual(TCPFlags.psh.rawValue, 0b001000)
        XCTAssertEqual(TCPFlags.ack.rawValue, 0b010000)
        XCTAssertEqual(TCPFlags.urg.rawValue, 0b100000)
    }

    func testSetSemantics() {
        let synAck: TCPFlags = [.syn, .ack]
        XCTAssertTrue(synAck.contains(.syn))
        XCTAssertTrue(synAck.contains(.ack))
        XCTAssertFalse(synAck.contains(.fin))
        XCTAssertEqual(synAck.rawValue, TCPFlags.syn.rawValue | TCPFlags.ack.rawValue)
    }

    func testUnionIntersectionSubtraction() {
        let a: TCPFlags = [.syn, .ack]
        let b: TCPFlags = [.ack, .psh]
        XCTAssertEqual(a.union(b), [.syn, .ack, .psh])
        XCTAssertEqual(a.intersection(b), [.ack])
        XCTAssertEqual(a.subtracting(b), [.syn])
    }

    func testEmptyFlags() {
        let none = TCPFlags(rawValue: 0)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(none.description, "-")
    }

    func testDescription() {
        XCTAssertEqual((TCPFlags([.syn, .ack])).description, "SYN|ACK")
        XCTAssertEqual((TCPFlags([.fin, .ack])).description, "ACK|FIN")
    }

    func testCodableRoundTripEncodesRawValue() throws {
        let flags: TCPFlags = [.syn, .ack]
        let data = try JSONEncoder().encode(flags)
        // Debe serializarse como el byte crudo, no como un objeto.
        XCTAssertEqual(String(data: data, encoding: .utf8), "18")
        let decoded = try JSONDecoder().decode(TCPFlags.self, from: data)
        XCTAssertEqual(decoded, flags)
    }
}
