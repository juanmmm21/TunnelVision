import XCTest
@testable import Shared

final class FlowKeyTests: XCTestCase {
    private let deviceIP = ModelFixtures.v4(10, 0, 0, 2)      // dispositivo (local)
    private let remoteIP = ModelFixtures.v4(93, 184, 216, 34) // servidor remoto

    private var local: IPEndpoint { ModelFixtures.endpoint(deviceIP, 51000) }
    private var remote: IPEndpoint { ModelFixtures.endpoint(remoteIP, 443) }

    func testCanonicalizationIsDirectionIndependent() {
        let outboundKey = FlowKey(proto: .tcp, source: local, destination: remote)
        let inboundKey = FlowKey(proto: .tcp, source: remote, destination: local)
        XCTAssertEqual(outboundKey, inboundKey)
        XCTAssertEqual(outboundKey.hashValue, inboundKey.hashValue)
    }

    func testEndpointsAreSortedCanonically() {
        let key = FlowKey(proto: .tcp, source: remote, destination: local)
        XCTAssertLessThanOrEqual(key.endpointA, key.endpointB)
    }

    func testDifferentProtocolProducesDifferentKey() {
        let tcp = FlowKey(proto: .tcp, source: local, destination: remote)
        let udp = FlowKey(proto: .udp, source: local, destination: remote)
        XCTAssertNotEqual(tcp, udp)
    }

    func testDirectionIsCorrectForBothEnds() {
        let key = FlowKey(proto: .tcp, source: local, destination: remote)
        // El paquete cuyo origen es el dispositivo va hacia fuera; la respuesta, hacia dentro.
        XCTAssertEqual(key.direction(ofPacketFrom: local, localAddress: deviceIP), .outbound)
        XCTAssertEqual(key.direction(ofPacketFrom: remote, localAddress: deviceIP), .inbound)
    }

    func testDirectionIndependentOfConstructionOrder() {
        // La clave construida en sentido inbound debe clasificar igual que la construida outbound.
        let key = FlowKey(proto: .tcp, source: remote, destination: local)
        XCTAssertEqual(key.direction(ofPacketFrom: local, localAddress: deviceIP), .outbound)
        XCTAssertEqual(key.direction(ofPacketFrom: remote, localAddress: deviceIP), .inbound)
    }

    func testDirectionForIPv6Flow() {
        let deviceV6 = ModelFixtures.v6(0xfe80, 0, 0, 0, 0, 0, 0, 0x0001)
        let remoteV6 = ModelFixtures.v6(0x2606, 0x2800, 0x220, 0, 0, 0, 0, 0x0001)
        let localV6 = ModelFixtures.endpoint(deviceV6, 52000)
        let remoteEndpointV6 = ModelFixtures.endpoint(remoteV6, 443)
        let key = FlowKey(proto: .tcp, source: localV6, destination: remoteEndpointV6)
        XCTAssertEqual(key.direction(ofPacketFrom: localV6, localAddress: deviceV6), .outbound)
        XCTAssertEqual(key.direction(ofPacketFrom: remoteEndpointV6, localAddress: deviceV6), .inbound)
    }
}
