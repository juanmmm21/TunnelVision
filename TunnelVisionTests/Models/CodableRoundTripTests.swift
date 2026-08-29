import XCTest
@testable import Shared

final class CodableRoundTripTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #file, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    func testEnumsRoundTrip() throws {
        try roundTrip(IPVersion.v4)
        try roundTrip(IPVersion.v6)
        try roundTrip(IPProtocolNumber.tcp)
        try roundTrip(IPProtocolNumber.other)
        try roundTrip(Direction.outbound)
        try roundTrip(Direction.inbound)
        try roundTrip(TLSInspectionStatus.plaintext)
        try roundTrip(TLSInspectionStatus.inspected)
        try roundTrip(TLSInspectionStatus.notInspectable)
    }

    func testAddressAndEndpointRoundTrip() throws {
        try roundTrip(ModelFixtures.v4(192, 168, 0, 1))
        try roundTrip(ModelFixtures.v6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1))
        try roundTrip(ModelFixtures.endpoint(ModelFixtures.v4(10, 0, 0, 2), 443))
    }

    func testFlowKeyRoundTrip() throws {
        let key = FlowKey(
            proto: .udp,
            source: ModelFixtures.endpoint(ModelFixtures.v4(10, 0, 0, 2), 55000),
            destination: ModelFixtures.endpoint(ModelFixtures.v4(1, 1, 1, 1), 53)
        )
        try roundTrip(key)
    }

    func testPacketMetaRoundTrip() throws {
        let key = FlowKey(
            proto: .tcp,
            source: ModelFixtures.endpoint(ModelFixtures.v4(10, 0, 0, 2), 51000),
            destination: ModelFixtures.endpoint(ModelFixtures.v4(93, 184, 216, 34), 443)
        )
        let meta = PacketMeta(
            timestamp: 1_234_567_890,
            flowKey: key,
            direction: .outbound,
            length: 1420,
            tcpFlags: [.syn, .ack],
            capture: CaptureLocation(fileSequence: 2, recordOffset: 24)
        )
        try roundTrip(meta)
    }

    func testFlowRecordRoundTrip() throws {
        let key = FlowKey(
            proto: .tcp,
            source: ModelFixtures.endpoint(ModelFixtures.v4(10, 0, 0, 2), 51000),
            destination: ModelFixtures.endpoint(ModelFixtures.v4(93, 184, 216, 34), 443)
        )
        let withSNI = FlowRecord(
            id: 7,
            key: key,
            firstSeen: 1_000,
            lastSeen: 2_000,
            bytesOut: 4096,
            bytesIn: 8192,
            packetCount: 12,
            tlsStatus: .inspected,
            sni: "example.com"
        )
        try roundTrip(withSNI)

        // `sni` opcional a nil también debe round-tripear.
        let withoutSNI = FlowRecord(
            id: 8,
            key: key,
            firstSeen: 1_000,
            lastSeen: 2_000,
            bytesOut: 0,
            bytesIn: 0,
            packetCount: 1,
            tlsStatus: .encrypted,
            sni: nil
        )
        try roundTrip(withoutSNI)
    }

    func testPacketMetaEquatableAndHashable() {
        let key = FlowKey(
            proto: .tcp,
            source: ModelFixtures.endpoint(ModelFixtures.v4(10, 0, 0, 2), 51000),
            destination: ModelFixtures.endpoint(ModelFixtures.v4(93, 184, 216, 34), 443)
        )
        let a = PacketMeta(timestamp: 1, flowKey: key, direction: .inbound, length: 100, tcpFlags: [.ack], capture: nil)
        let b = PacketMeta(timestamp: 1, flowKey: key, direction: .inbound, length: 100, tcpFlags: [.ack], capture: nil)
        let c = PacketMeta(timestamp: 2, flowKey: key, direction: .inbound, length: 100, tcpFlags: [.ack], capture: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
    }

    func testProtocolNumberWireValueMapping() {
        XCTAssertEqual(IPProtocolNumber(wireValue: 6), .tcp)
        XCTAssertEqual(IPProtocolNumber(wireValue: 17), .udp)
        XCTAssertEqual(IPProtocolNumber(wireValue: 50), .other) // ESP → other
        XCTAssertEqual(IPProtocolNumber(wireValue: 1), .icmp)
    }
}
