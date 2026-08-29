import Foundation
import XCTest
import Shared

/// Tests del parser M3. Los vectores golden se construyen en `PacketFixtures` (registros
/// raw-IP deterministas). Cubren: extracción de campos IPv4/IPv6 + TCP/UDP, canonicalización del
/// `FlowKey`, extension headers IPv6, fragmentos, protocolos no soportados (sin throw), entradas
/// malformadas (con el `PacketParseError` correcto) y un fuzz que no debe crashear.
final class PacketParserTests: XCTestCase {

    private let hintV4 = AF_INET
    private let hintV6 = AF_INET6

    // MARK: - IPv4

    func testParsesIPv4TcpSyn() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv4TcpSyn(), protocolFamily: hintV4)

        XCTAssertEqual(parsed.ip.version, .v4)
        XCTAssertEqual(parsed.ip.proto, .tcp)
        XCTAssertEqual(parsed.ip.rawProtocol, 6)
        XCTAssertEqual(parsed.ip.totalLength, 40)
        XCTAssertEqual(parsed.ip.payloadRange, 20..<40)
        XCTAssertEqual(parsed.source, endpoint(PacketFixtures.localV4, 51000, .v4))
        XCTAssertEqual(parsed.destination, endpoint(PacketFixtures.remoteV4, 443, .v4))

        let tcp = try XCTUnwrap(parsed.tcp)
        XCTAssertNil(parsed.udp)
        XCTAssertEqual(tcp.sourcePort, 51000)
        XCTAssertEqual(tcp.destinationPort, 443)
        XCTAssertEqual(tcp.sequence, 0x12345678)
        XCTAssertEqual(tcp.acknowledgment, 0)
        XCTAssertEqual(tcp.flags, .syn)
        XCTAssertEqual(tcp.windowSize, 65535)
        XCTAssertEqual(tcp.dataOffsetBytes, 20)
        XCTAssertEqual(tcp.payloadRange, 40..<40)

        assertFlowKeyMatches(parsed)
    }

    func testParsesIPv4UdpDns() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv4UdpDns(), protocolFamily: hintV4)

        XCTAssertEqual(parsed.ip.proto, .udp)
        XCTAssertEqual(parsed.ip.totalLength, 32)
        XCTAssertEqual(parsed.ip.payloadRange, 20..<32)

        let udp = try XCTUnwrap(parsed.udp)
        XCTAssertNil(parsed.tcp)
        XCTAssertEqual(udp.sourcePort, 53535)
        XCTAssertEqual(udp.destinationPort, 53)
        XCTAssertEqual(udp.length, 12)
        XCTAssertEqual(udp.payloadRange, 28..<32)
        XCTAssertEqual(parsed.source, endpoint(PacketFixtures.localV4, 53535, .v4))
        XCTAssertEqual(parsed.destination, endpoint(PacketFixtures.dnsV4, 53, .v4))
        assertFlowKeyMatches(parsed)
    }

    // MARK: - IPv6

    func testParsesIPv6Tcp() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv6Tcp(), protocolFamily: hintV6)

        XCTAssertEqual(parsed.ip.version, .v6)
        XCTAssertEqual(parsed.ip.proto, .tcp)
        XCTAssertEqual(parsed.ip.totalLength, 60)
        XCTAssertEqual(parsed.ip.payloadRange, 40..<60)

        let tcp = try XCTUnwrap(parsed.tcp)
        XCTAssertEqual(tcp.sourcePort, 50000)
        XCTAssertEqual(tcp.destinationPort, 443)
        XCTAssertEqual(tcp.sequence, 0xAABBCCDD)
        XCTAssertEqual(tcp.acknowledgment, 0x01020304)
        XCTAssertEqual(tcp.flags, [.psh, .ack])
        XCTAssertEqual(tcp.windowSize, 4096)
        XCTAssertEqual(parsed.source, endpoint(PacketFixtures.localV6, 50000, .v6))
        XCTAssertEqual(parsed.destination, endpoint(PacketFixtures.remoteV6, 443, .v6))
        assertFlowKeyMatches(parsed)
    }

    func testParsesIPv6Udp() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv6Udp(), protocolFamily: hintV6)

        XCTAssertEqual(parsed.ip.proto, .udp)
        XCTAssertEqual(parsed.ip.totalLength, 51)
        XCTAssertEqual(parsed.ip.payloadRange, 40..<51)

        let udp = try XCTUnwrap(parsed.udp)
        XCTAssertEqual(udp.sourcePort, 33333)
        XCTAssertEqual(udp.destinationPort, 443)
        XCTAssertEqual(udp.length, 11)
        XCTAssertEqual(udp.payloadRange, 48..<51)
        assertFlowKeyMatches(parsed)
    }

    func testParsesIPv6WithExtensionHeaders() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv6ExtHeadersTcp(), protocolFamily: hintV6)

        // El transporte está tras la hop-by-hop de 8 bytes: el payload L4 arranca en offset 48.
        XCTAssertEqual(parsed.ip.proto, .tcp)
        XCTAssertEqual(parsed.ip.totalLength, 68)
        XCTAssertEqual(parsed.ip.payloadRange, 48..<68)

        let tcp = try XCTUnwrap(parsed.tcp)
        XCTAssertEqual(tcp.sourcePort, 40000)
        XCTAssertEqual(tcp.destinationPort, 8080)
        XCTAssertEqual(tcp.flags, .ack)
        XCTAssertEqual(tcp.payloadRange, 68..<68)
        assertFlowKeyMatches(parsed)
    }

    // MARK: - Fragmentos y protocolos sin transporte

    func testNonFirstFragmentHasNoL4() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv4NonFirstFragment(), protocolFamily: hintV4)

        // El protocolo IP sigue siendo TCP, pero un fragmento no-inicial no lleva cabecera L4.
        XCTAssertEqual(parsed.ip.proto, .tcp)
        XCTAssertNil(parsed.tcp)
        XCTAssertNil(parsed.udp)
        XCTAssertEqual(parsed.source.port, 0)
        XCTAssertEqual(parsed.destination.port, 0)
        XCTAssertEqual(parsed.ip.payloadRange, 20..<44)
    }

    func testIcmpIsNotAnError() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv4Icmp(), protocolFamily: hintV4)
        XCTAssertEqual(parsed.ip.proto, .icmp)
        XCTAssertEqual(parsed.ip.rawProtocol, 1)
        XCTAssertNil(parsed.tcp)
        XCTAssertNil(parsed.udp)
        XCTAssertEqual(parsed.source.port, 0)
    }

    func testIcmpv6IsNotAnError() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv6Icmpv6(), protocolFamily: hintV6)
        XCTAssertEqual(parsed.ip.proto, .icmpv6)
        XCTAssertEqual(parsed.ip.rawProtocol, 58)
        XCTAssertNil(parsed.tcp)
        XCTAssertNil(parsed.udp)
    }

    func testUnsupportedTransportCollapsesToOther() throws {
        let parsed = try PacketParser.parse(PacketFixtures.ipv4Esp(), protocolFamily: hintV4)
        XCTAssertEqual(parsed.ip.proto, .other)
        XCTAssertEqual(parsed.ip.rawProtocol, 50)   // el valor real se conserva
        XCTAssertNil(parsed.tcp)
        XCTAssertNil(parsed.udp)
    }

    // MARK: - La pista de familia no manda; gana el contenido

    func testContentWinsOverProtocolFamilyHint() throws {
        // Se pasa la pista equivocada (AF_INET6) para un datagrama IPv4: debe ganar el nibble.
        let parsed = try PacketParser.parse(PacketFixtures.ipv4TcpSyn(), protocolFamily: hintV6)
        XCTAssertEqual(parsed.ip.version, .v4)
        XCTAssertEqual(parsed.ip.proto, .tcp)
    }

    // MARK: - Entradas malformadas → PacketParseError tipado

    func testEmptyBufferThrowsTooShort() {
        assertThrows(Data(), .tooShort(expected: 1, got: 0))
    }

    func testUnsupportedVersionThrows() {
        assertThrows(Data([0x70, 0x00]), .unsupportedVersion(7))
    }

    func testIPv4TruncatedHeaderThrowsTooShort() {
        let truncated = PacketFixtures.ipv4TcpSyn().prefix(19)
        assertThrows(Data(truncated), .tooShort(expected: 20, got: 19))
    }

    func testIPv4BadHeaderLengthThrows() {
        // IHL = 4 (16 bytes): por debajo del mínimo legal de 20.
        var bytes = [UInt8](PacketFixtures.ipv4TcpSyn())
        bytes[0] = 0x44
        assertThrows(Data(bytes), .badHeaderLength)
    }

    func testIPv4TruncatedL4Throws() {
        // Cabecera IPv4 completa (20 bytes) pero sin segmento TCP detrás.
        let truncated = PacketFixtures.ipv4TcpSyn().prefix(20)
        assertThrows(Data(truncated), .truncatedL4)
    }

    func testIPv6TruncatedBaseHeaderThrows() {
        let truncated = PacketFixtures.ipv6Tcp().prefix(39)
        assertThrows(Data(truncated), .tooShort(expected: 40, got: 39))
    }

    func testIPv6TruncatedL4Throws() {
        let truncated = PacketFixtures.ipv6Tcp().prefix(40)
        assertThrows(Data(truncated), .truncatedL4)
    }

    func testTcpBadDataOffsetThrows() {
        // Data offset = 4 words (16 bytes) < 20: cabecera TCP estructuralmente inválida.
        var bytes = [UInt8](PacketFixtures.ipv4TcpSyn())
        bytes[20 + 12] = 0x40
        assertThrows(Data(bytes), .badHeaderLength)
    }

    // MARK: - Fuzz: nunca crashea, solo lanza PacketParseError

    func testFuzzNeverCrashes() {
        var generator = SystemRandomNumberGenerator()
        let families: [Int32] = [AF_INET, AF_INET6, 0, -1]
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...80, using: &generator)
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
            let family = families.randomElement(using: &generator) ?? AF_INET
            do {
                _ = try PacketParser.parse(Data(bytes), protocolFamily: family)
            } catch is PacketParseError {
                // Esperado: cualquier fallo estructural es un PacketParseError.
            } catch {
                XCTFail("El parser lanzó un error no tipado: \(error)")
            }
        }
    }

    // MARK: - Benchmark del hot path

    func testParsePerformance() {
        let packet = PacketFixtures.ipv4TcpSyn()
        measure {
            for _ in 0..<50_000 {
                _ = try? PacketParser.parse(packet, protocolFamily: AF_INET)
            }
        }
    }

    // MARK: - Helpers

    private func endpoint(_ addressBytes: [UInt8], _ port: UInt16, _ version: IPVersion) -> IPEndpoint {
        IPEndpoint(address: IPAddress(version: version, bytes: addressBytes), port: port)
    }

    /// El `FlowKey` del resultado debe coincidir con la clave canónica reconstruida a partir de
    /// los endpoints origen/destino extraídos.
    private func assertFlowKeyMatches(_ parsed: ParsedPacket, file: StaticString = #filePath, line: UInt = #line) {
        let expected = FlowKey(proto: parsed.ip.proto, source: parsed.source, destination: parsed.destination)
        XCTAssertEqual(parsed.flowKey, expected, file: file, line: line)
    }

    private func assertThrows(
        _ packet: Data,
        _ expected: PacketParseError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PacketParser.parse(packet, protocolFamily: AF_INET), file: file, line: line) { error in
            guard let parseError = error as? PacketParseError else {
                XCTFail("Se esperaba PacketParseError, llegó \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(parseError, expected, file: file, line: line)
        }
    }
}
