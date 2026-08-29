import Foundation
import XCTest
import Shared

/// Tests del emisor M8. Los vectores golden están calculados a mano (checksums incluidos, siguiendo
/// RFC 791/768/9293/8200) y escritos byte a byte, no capturados de una ejecución de este código: un
/// golden generado por el propio emisor solo probaría que no ha cambiado, no que es correcto.
///
/// Encima de eso hay dos redes: el round-trip contra el `PacketParser` de M3 (dos implementaciones
/// independientes que deben coincidir) y un verificador de checksums escrito aparte en este fichero,
/// sin usar `InternetChecksum`, que aplica la propiedad del RFC 1071 (sumar un bloque junto a su
/// checksum da cero) tal y como la aplicaría el receptor.
final class PacketEmitterTests: XCTestCase {

    // MARK: - Endpoints de referencia

    private let localV4 = IPEndpoint(address: IPAddress(version: .v4, bytes: PacketFixtures.localV4), port: 51000)
    private let remoteV4 = IPEndpoint(address: IPAddress(version: .v4, bytes: PacketFixtures.remoteV4), port: 443)
    private let localV6 = IPEndpoint(address: IPAddress(version: .v6, bytes: PacketFixtures.localV6), port: 50000)
    private let remoteV6 = IPEndpoint(address: IPAddress(version: .v6, bytes: PacketFixtures.remoteV6), port: 443)

    private func v4(_ bytes: [UInt8], _ port: UInt16) -> IPEndpoint {
        IPEndpoint(address: IPAddress(version: .v4, bytes: bytes), port: port)
    }

    private func v6(_ bytes: [UInt8], _ port: UInt16) -> IPEndpoint {
        IPEndpoint(address: IPAddress(version: .v6, bytes: bytes), port: port)
    }

    // MARK: - Golden: IPv4 + TCP

    /// SYN de 10.0.0.2:51000 a 93.184.216.34:443. Checksum IP 0xfaf3, checksum TCP 0x3e66.
    func testEmitsIPv4TcpSynByteExact() throws {
        let datagram = try PacketEmitter.tcp(
            source: localV4,
            destination: remoteV4,
            sequence: 0x1234_5678,
            acknowledgment: 0,
            flags: .syn,
            windowSize: 65535
        )

        let expected: [UInt8] = [
            // --- IPv4 ---
            0x45, 0x00,                 // versión 4, IHL 5; DSCP/ECN 0
            0x00, 0x28,                 // total length = 40
            0x00, 0x00,                 // identification
            0x40, 0x00,                 // flags: DF; fragment offset 0
            0x40,                       // TTL 64
            0x06,                       // proto TCP
            0xfa, 0xf3,                 // checksum de cabecera
            0x0a, 0x00, 0x00, 0x02,     // 10.0.0.2
            0x5d, 0xb8, 0xd8, 0x22,     // 93.184.216.34
            // --- TCP ---
            0xc7, 0x38,                 // puerto origen 51000
            0x01, 0xbb,                 // puerto destino 443
            0x12, 0x34, 0x56, 0x78,     // sequence
            0x00, 0x00, 0x00, 0x00,     // acknowledgment
            0x50,                       // data offset 5 palabras, reservados 0
            0x02,                       // flags: SYN
            0xff, 0xff,                 // window
            0x3e, 0x66,                 // checksum
            0x00, 0x00,                 // urgent pointer
        ]
        XCTAssertEqual([UInt8](datagram), expected)
        assertChecksumsVerify(datagram)
    }

    // MARK: - Golden: IPv4 + UDP

    /// Consulta DNS de 10.0.0.2:53535 a 8.8.8.8:53. Checksum IP 0x20bc, checksum UDP 0x9cd6.
    func testEmitsIPv4UdpByteExact() throws {
        let datagram = try PacketEmitter.udp(
            source: v4(PacketFixtures.localV4, 53535),
            destination: v4(PacketFixtures.dnsV4, 53),
            payload: Data([0xaa, 0xbb, 0xcc, 0xdd])
        )

        let expected: [UInt8] = [
            0x45, 0x00,
            0x00, 0x20,                 // total length = 32
            0x00, 0x00,
            0x40, 0x00,
            0x40,
            0x11,                       // proto UDP
            0x20, 0xbc,                 // checksum de cabecera
            0x0a, 0x00, 0x00, 0x02,
            0x08, 0x08, 0x08, 0x08,
            // --- UDP ---
            0xd1, 0x1f,                 // puerto origen 53535
            0x00, 0x35,                 // puerto destino 53
            0x00, 0x0c,                 // length = 12 (8 de cabecera + 4 de payload)
            0x9c, 0xd6,                 // checksum
            0xaa, 0xbb, 0xcc, 0xdd,     // payload
        ]
        XCTAssertEqual([UInt8](datagram), expected)
        assertChecksumsVerify(datagram)
    }

    // MARK: - Golden: IPv6 + TCP

    /// PSH|ACK de [2001:db8::1]:50000 a [2001:db8::2]:443. Checksum TCP 0x03ad (IPv6 no lleva
    /// checksum de cabecera: lo delegó entero en la capa de transporte).
    func testEmitsIPv6TcpByteExact() throws {
        let datagram = try PacketEmitter.tcp(
            source: localV6,
            destination: remoteV6,
            sequence: 0xaabb_ccdd,
            acknowledgment: 0x0102_0304,
            flags: [.psh, .ack],
            windowSize: 4096
        )

        var expected: [UInt8] = [
            0x60, 0x00, 0x00, 0x00,     // versión 6, traffic class y flow label a 0
            0x00, 0x14,                 // payload length = 20 (sin la cabecera base)
            0x06,                       // next header: TCP
            0x40,                       // hop limit 64
        ]
        expected += PacketFixtures.localV6
        expected += PacketFixtures.remoteV6
        expected += [
            0xc3, 0x50,                 // puerto origen 50000
            0x01, 0xbb,                 // puerto destino 443
            0xaa, 0xbb, 0xcc, 0xdd,     // sequence
            0x01, 0x02, 0x03, 0x04,     // acknowledgment
            0x50,                       // data offset 5 palabras
            0x18,                       // flags: PSH|ACK
            0x10, 0x00,                 // window 4096
            0x03, 0xad,                 // checksum
            0x00, 0x00,                 // urgent pointer
        ]
        XCTAssertEqual([UInt8](datagram), expected)
        assertChecksumsVerify(datagram)
    }

    // MARK: - Golden: IPv6 + UDP con payload impar

    /// Payload de 3 bytes: obliga a rellenar la última palabra con un cero al calcular el checksum
    /// (RFC 1071), sin que ese relleno viaje en el datagrama. Checksum UDP 0x1c71.
    func testEmitsIPv6UdpWithOddPayloadByteExact() throws {
        let datagram = try PacketEmitter.udp(
            source: v6(PacketFixtures.localV6, 33333),
            destination: remoteV6,
            payload: Data([0x01, 0x02, 0x03])
        )

        var expected: [UInt8] = [
            0x60, 0x00, 0x00, 0x00,
            0x00, 0x0b,                 // payload length = 11 (8 + 3)
            0x11,                       // next header: UDP
            0x40,
        ]
        expected += PacketFixtures.localV6
        expected += PacketFixtures.remoteV6
        expected += [
            0x82, 0x35,                 // puerto origen 33333
            0x01, 0xbb,                 // puerto destino 443
            0x00, 0x0b,                 // length = 11
            0x1c, 0x71,                 // checksum
            0x01, 0x02, 0x03,           // payload (3 bytes: el relleno no se emite)
        ]
        XCTAssertEqual([UInt8](datagram), expected)
        assertChecksumsVerify(datagram)
    }

    // MARK: - Regla del checksum cero en UDP

    /// Payload elegido para que la suma dé exactamente 0xffff y el checksum calculado sea 0. RFC 768
    /// reserva el cero para "sin checksum", así que debe transmitirse como todo unos.
    func testUdpChecksumOfZeroIsTransmittedAsAllOnes() throws {
        let datagram = try PacketEmitter.udp(
            source: v4(PacketFixtures.localV4, 53535),
            destination: v4(PacketFixtures.dnsV4, 53),
            payload: Data([0x14, 0x74])
        )

        let udpChecksum = [UInt8](datagram)[26..<28]
        XCTAssertEqual([UInt8](udpChecksum), [0xff, 0xff])

        // 0xffff y 0x0000 son el mismo número en complemento a uno, así que el receptor valida igual.
        assertChecksumsVerify(datagram)
    }

    // MARK: - Round-trip contra el parser de M3

    func testRoundTripsThroughParserIPv4Tcp() throws {
        let payload = Data("GET / HTTP/1.1\r\n\r\n".utf8)
        let datagram = try PacketEmitter.tcp(
            source: localV4,
            destination: remoteV4,
            sequence: 0x0000_0001,
            acknowledgment: 0xffff_fffe,
            flags: [.psh, .ack],
            windowSize: 1024,
            payload: payload
        )

        let parsed = try PacketParser.parse(datagram, protocolFamily: AF_INET)

        XCTAssertEqual(parsed.ip.version, .v4)
        XCTAssertEqual(parsed.ip.proto, .tcp)
        XCTAssertEqual(parsed.ip.rawProtocol, 6)
        XCTAssertEqual(parsed.ip.totalLength, 20 + 20 + payload.count)
        XCTAssertEqual(parsed.source, localV4)
        XCTAssertEqual(parsed.destination, remoteV4)

        let tcp = try XCTUnwrap(parsed.tcp)
        XCTAssertEqual(tcp.sequence, 0x0000_0001)
        XCTAssertEqual(tcp.acknowledgment, 0xffff_fffe)
        XCTAssertEqual(tcp.flags, [.psh, .ack])
        XCTAssertEqual(tcp.windowSize, 1024)
        XCTAssertEqual(tcp.dataOffsetBytes, 20)
        XCTAssertEqual(datagram[tcp.payloadRange], payload)
    }

    func testRoundTripsThroughParserIPv6Udp() throws {
        let payload = Data([UInt8](repeating: 0x5a, count: 512))
        let datagram = try PacketEmitter.udp(source: localV6, destination: remoteV6, payload: payload)

        let parsed = try PacketParser.parse(datagram, protocolFamily: AF_INET6)

        XCTAssertEqual(parsed.ip.version, .v6)
        XCTAssertEqual(parsed.ip.proto, .udp)
        XCTAssertEqual(parsed.source, localV6)
        XCTAssertEqual(parsed.destination, remoteV6)

        let udp = try XCTUnwrap(parsed.udp)
        XCTAssertEqual(udp.length, UInt16(8 + payload.count))
        XCTAssertEqual(datagram[udp.payloadRange], payload)
    }

    /// El `FlowKey` es canónico: emitir el mismo flujo en un sentido y en el contrario debe producir
    /// la misma clave. Es lo que permite al relay reinyectar una respuesta y que el pipeline la
    /// agregue en el flujo que ya existía en vez de crear uno nuevo.
    func testFlowKeySurvivesDirectionInversion() throws {
        let outbound = try PacketEmitter.tcp(
            source: localV4, destination: remoteV4,
            sequence: 1, acknowledgment: 0, flags: .syn, windowSize: 100
        )
        let inbound = try PacketEmitter.tcp(
            source: remoteV4, destination: localV4,
            sequence: 0, acknowledgment: 2, flags: [.syn, .ack], windowSize: 100
        )

        let outKey = try PacketParser.parse(outbound, protocolFamily: AF_INET).flowKey
        let inKey = try PacketParser.parse(inbound, protocolFamily: AF_INET).flowKey
        XCTAssertEqual(outKey, inKey)
    }

    // MARK: - Flags

    /// `TCPFlags` solo modela los bits 0..5. Un `rawValue` con ECE/CWR (bits 6-7) puestos no debe
    /// emitirlos: anunciaríamos un ECN que no implementamos.
    func testUnmodelledFlagBitsAreMaskedOut() throws {
        let datagram = try PacketEmitter.tcp(
            source: localV4, destination: remoteV4,
            sequence: 0, acknowledgment: 0,
            flags: TCPFlags(rawValue: 0xc2),    // CWR|ECE|SYN
            windowSize: 0
        )

        XCTAssertEqual([UInt8](datagram)[33], 0x02)     // solo SYN llega al cable
        assertChecksumsVerify(datagram)

        let tcp = try XCTUnwrap(try PacketParser.parse(datagram, protocolFamily: AF_INET).tcp)
        XCTAssertEqual(tcp.flags, .syn)
    }

    // MARK: - Propiedad: los checksums siempre validan

    /// Barrido sobre longitudes de payload (pares e impares, cruzando el borde de palabra) y sobre
    /// contenidos con bytes altos, que son los que fuerzan acarreos. Cada datagrama se valida con el
    /// verificador independiente y se re-parsea.
    func testChecksumsVerifyAcrossPayloadLengths() throws {
        var generator = SystemRandomNumberGenerator()

        for length in 0...64 {
            let payload = Data((0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) })

            let tcpV4 = try PacketEmitter.tcp(
                source: localV4, destination: remoteV4,
                sequence: 7, acknowledgment: 9, flags: .ack, windowSize: 512, payload: payload
            )
            assertChecksumsVerify(tcpV4, "TCP v4, payload de \(length) B")
            XCTAssertEqual(try PacketParser.parse(tcpV4, protocolFamily: AF_INET).tcp?.payloadRange.count, length)

            let udpV6 = try PacketEmitter.udp(source: localV6, destination: remoteV6, payload: payload)
            assertChecksumsVerify(udpV6, "UDP v6, payload de \(length) B")
            XCTAssertEqual(try PacketParser.parse(udpV6, protocolFamily: AF_INET6).udp?.payloadRange.count, length)
        }
    }

    // MARK: - Golden: capa superior opaca (ICMP)

    /// Echo request ICMPv4 de 93.184.216.34 a 10.0.0.2. El payload va tal cual —checksum ICMP
    /// incluido, que es de quien lo compone— y solo la cabecera IPv4 la pone el emisor: checksum
    /// 0xfb04 sobre `45 00 00 1c 00 00 40 00 40 01 00 00 5d b8 d8 22 0a 00 00 02`.
    func testEmitsIPv4OpaqueUpperLayerByteExact() throws {
        // Echo request: tipo 8, código 0, checksum 0xf7fb, id 1, secuencia 1.
        let icmp = Data([0x08, 0x00, 0xf7, 0xfb, 0x00, 0x01, 0x00, 0x01])
        let datagram = try PacketEmitter.datagram(
            source: remoteV4.address,
            destination: localV4.address,
            rawProtocol: IPProtocolNumber.icmp.rawValue,
            payload: icmp
        )

        let expected = Data([
            0x45, 0x00, 0x00, 0x1c,             // versión/IHL, DSCP/ECN, total length 28
            0x00, 0x00, 0x40, 0x00,             // identification 0, DF
            0x40, 0x01, 0xfb, 0x04,             // TTL 64, proto 1 (ICMP), checksum
            93, 184, 216, 34,
            10, 0, 0, 2,
        ]) + icmp
        XCTAssertEqual(datagram, expected)

        // El golden de arriba está calculado a mano, así que la red de abajo es el verificador
        // independiente: solo la cabecera IP, porque el checksum del payload opaco no es de este
        // emisor y no tiene por qué cubrir una pseudo-cabecera.
        XCTAssertEqual(onesComplementSum([UInt8](datagram)[0..<20]), 0xffff)
    }

    /// La cabecera IPv6 no lleva checksum, así que el datagrama es la cabecera base más el payload
    /// literal: aquí lo que se afirma es el `next header` (58) y el `payload length`.
    func testEmitsIPv6OpaqueUpperLayerByteExact() throws {
        let icmpv6 = Data([0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01])
        let datagram = try PacketEmitter.datagram(
            source: remoteV6.address,
            destination: localV6.address,
            rawProtocol: IPProtocolNumber.icmpv6.rawValue,
            payload: icmpv6
        )

        var expected = Data([0x60, 0x00, 0x00, 0x00, 0x00, 0x08, 0x3a, 0x40])
        expected.append(contentsOf: PacketFixtures.remoteV6)
        expected.append(contentsOf: PacketFixtures.localV6)
        expected += icmpv6
        XCTAssertEqual(datagram, expected)
    }

    /// El parser sí acepta estos protocolos (sin puertos, como metadato), así que el round-trip
    /// cierra el círculo: lo que el emisor produce para ICMP es un flujo que la app puede llegar a
    /// tener guardado, con sus dos puertos a cero.
    func testRoundTripsThroughParserForOpaqueUpperLayer() throws {
        let payload = Data([0x08, 0x00, 0xf7, 0xfb, 0x00, 0x01, 0x00, 0x01])
        let datagram = try PacketEmitter.datagram(
            source: remoteV4.address,
            destination: localV4.address,
            rawProtocol: IPProtocolNumber.icmp.rawValue,
            payload: payload
        )

        let parsed = try PacketParser.parse(datagram, protocolFamily: AF_INET)
        XCTAssertEqual(parsed.ip.proto, .icmp)
        XCTAssertEqual(parsed.ip.rawProtocol, 1)
        XCTAssertNil(parsed.tcp)
        XCTAssertNil(parsed.udp)
        XCTAssertEqual(parsed.source.port, 0)
        XCTAssertEqual(parsed.destination.port, 0)
        XCTAssertEqual(parsed.source.address, remoteV4.address)
        XCTAssertEqual(parsed.destination.address, localV4.address)
        XCTAssertEqual(Data(datagram[parsed.ip.payloadRange]), payload)
    }

    /// Un número de protocolo que `IPProtocolNumber` no modela (ESP, 50) viaja crudo en la cabecera y
    /// el parser lo colapsa a `.other` conservando el valor original. Es el caso que hace que el
    /// filtro *Other* de la Timeline tenga algo que recoger.
    func testUnmodelledProtocolNumberSurvivesRoundTrip() throws {
        let datagram = try PacketEmitter.datagram(
            source: remoteV4.address,
            destination: localV4.address,
            rawProtocol: 50,
            payload: Data(repeating: 0x00, count: 16)
        )

        let parsed = try PacketParser.parse(datagram, protocolFamily: AF_INET)
        XCTAssertEqual(parsed.ip.proto, .other)
        XCTAssertEqual(parsed.ip.rawProtocol, 50)
        XCTAssertEqual(parsed.flowKey.proto, .other)
    }

    // MARK: - Errores

    func testMismatchedAddressFamiliesThrow() {
        XCTAssertThrowsError(
            try PacketEmitter.tcp(
                source: localV4, destination: remoteV6,
                sequence: 0, acknowledgment: 0, flags: .syn, windowSize: 0
            )
        ) { error in
            XCTAssertEqual(error as? PacketEmitError, .addressFamilyMismatch(source: .v4, destination: .v6))
        }

        XCTAssertThrowsError(
            try PacketEmitter.udp(source: localV6, destination: remoteV4, payload: Data())
        ) { error in
            XCTAssertEqual(error as? PacketEmitError, .addressFamilyMismatch(source: .v6, destination: .v4))
        }

        XCTAssertThrowsError(
            try PacketEmitter.datagram(
                source: localV4.address, destination: remoteV6.address,
                rawProtocol: IPProtocolNumber.icmp.rawValue, payload: Data()
            )
        ) { error in
            XCTAssertEqual(error as? PacketEmitError, .addressFamilyMismatch(source: .v4, destination: .v6))
        }
    }

    /// El emisor no fragmenta: lo que no cabe en el campo de longitud es un error del caller, no algo
    /// que se recorte en silencio.
    func testOversizedDatagramsThrow() {
        // IPv4/TCP: 20 (IP) + 20 (TCP) + payload > 65535.
        let tcpV4Payload = Data(count: 65535 - 20 - 20 + 1)
        XCTAssertThrowsError(
            try PacketEmitter.tcp(
                source: localV4, destination: remoteV4,
                sequence: 0, acknowledgment: 0, flags: .ack, windowSize: 0, payload: tcpV4Payload
            )
        ) { error in
            XCTAssertEqual(error as? PacketEmitError, .datagramTooLarge(byteCount: 65536, limit: 65535))
        }

        // IPv6/TCP: el payload length excluye la cabecera base, así que el límite lo marca el segmento.
        let tcpV6Payload = Data(count: 65535 - 20 + 1)
        XCTAssertThrowsError(
            try PacketEmitter.tcp(
                source: localV6, destination: remoteV6,
                sequence: 0, acknowledgment: 0, flags: .ack, windowSize: 0, payload: tcpV6Payload
            )
        ) { error in
            XCTAssertEqual(error as? PacketEmitError, .datagramTooLarge(byteCount: 65536, limit: 65535))
        }

        // UDP: el campo `length` del propio UDP desborda antes que el de la cabecera IP.
        let udpPayload = Data(count: 65535 - 8 + 1)
        XCTAssertThrowsError(
            try PacketEmitter.udp(source: localV4, destination: remoteV4, payload: udpPayload)
        ) { error in
            XCTAssertEqual(error as? PacketEmitError, .datagramTooLarge(byteCount: 65536, limit: 65535))
        }

        // El payload opaco se mide con la misma regla: en IPv4 cuenta con su cabecera de 20 bytes.
        XCTAssertThrowsError(
            try PacketEmitter.datagram(
                source: localV4.address, destination: remoteV4.address,
                rawProtocol: IPProtocolNumber.icmp.rawValue,
                payload: Data(count: 65535 - 20 + 1)
            )
        ) { error in
            XCTAssertEqual(error as? PacketEmitError, .datagramTooLarge(byteCount: 65536, limit: 65535))
        }
    }

    // MARK: - Verificador independiente

    /// Valida los checksums de un datagrama como lo haría el receptor: suma en complemento a uno de
    /// cabecera IP (solo IPv4) y de pseudo-cabecera + segmento, incluyendo el campo de checksum tal y
    /// como viaja. Si el datagrama es correcto, ambas sumas dan cero.
    ///
    /// Escrito a mano y sin usar `InternetChecksum` a propósito: un verificador que reutilizase el
    /// tipo bajo test compartiría con él cualquier error de plegado o de pseudo-cabecera y no
    /// detectaría nada.
    private func assertChecksumsVerify(_ datagram: Data, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let bytes = [UInt8](datagram)

        let segment: ArraySlice<UInt8>
        let source: ArraySlice<UInt8>
        let destination: ArraySlice<UInt8>
        let proto: UInt8

        switch bytes[0] >> 4 {
        case 4:
            XCTAssertEqual(onesComplementSum(bytes[0..<20]), 0xffff, "checksum de cabecera IPv4. \(message)", file: file, line: line)
            proto = bytes[9]
            source = bytes[12..<16]
            destination = bytes[16..<20]
            segment = bytes[20...]
        case 6:
            proto = bytes[6]
            source = bytes[8..<24]
            destination = bytes[24..<40]
            segment = bytes[40...]
        default:
            return XCTFail("versión IP desconocida. \(message)", file: file, line: line)
        }

        var pseudo = [UInt8](source) + [UInt8](destination)
        if bytes[0] >> 4 == 4 {
            pseudo += [0, proto, UInt8(segment.count >> 8), UInt8(segment.count & 0xff)]
        } else {
            let length = UInt32(segment.count)
            pseudo += [UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)]
            pseudo += [0, 0, 0, proto]
        }

        let sum = onesComplementSum(pseudo[...] , segment)
        XCTAssertEqual(sum, 0xffff, "checksum de transporte. \(message)", file: file, line: line)
    }

    /// Suma en complemento a uno de 16 bits sobre la concatenación de los bloques, rellenando con un
    /// cero si el total es impar. Un resultado de 0xffff significa "verifica" (su complemento es 0).
    private func onesComplementSum(_ blocks: ArraySlice<UInt8>...) -> UInt16 {
        var bytes = [UInt8]()
        for block in blocks { bytes += block }
        if bytes.count % 2 != 0 { bytes.append(0) }

        var sum: UInt32 = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            // Plegado inmediato: mantiene la suma en 16 bits en todo momento, otra forma de hacerlo
            // distinta de la del código bajo test.
            if sum > 0xffff { sum = (sum & 0xffff) + 1 }
        }
        return UInt16(sum)
    }
}
