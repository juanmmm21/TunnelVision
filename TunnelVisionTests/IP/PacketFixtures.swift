import Foundation

/// Constructores de datagramas IP crudos para los tests del parser. Cada vector es equivalente
/// a un registro `LINKTYPE_RAW`: exactamente el datagrama IP, sin cabecera de enlace. Se generan
/// byte a byte (en vez de cargar `.pcap` binarios) para que el "golden" sea revisable en el diff
/// y determinista; el lector de `.pcap` real llega con M6 (`docs/spec/pcap.md`).
enum PacketFixtures {

    // MARK: - Direcciones de referencia

    static let localV4: [UInt8] = [10, 0, 0, 2]
    static let remoteV4: [UInt8] = [93, 184, 216, 34]
    static let dnsV4: [UInt8] = [8, 8, 8, 8]
    static let localV6: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
    static let remoteV6: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]

    // MARK: - Codificación big-endian

    static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xff)] }
    static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    // MARK: - Segmentos de transporte

    /// Cabecera TCP de 20 bytes (sin opciones). El checksum va a 0 (el parser lo ignora).
    static func tcpHeader(
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequence: UInt32,
        acknowledgment: UInt32,
        flagsByte: UInt8,
        window: UInt16,
        payload: [UInt8] = []
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += u16(sourcePort)
        bytes += u16(destinationPort)
        bytes += u32(sequence)
        bytes += u32(acknowledgment)
        bytes.append(0x50)          // data offset = 5 words (20 bytes), reservados 0
        bytes.append(flagsByte)
        bytes += u16(window)
        bytes += u16(0)             // checksum
        bytes += u16(0)             // urgent pointer
        bytes += payload
        return bytes
    }

    static func udpDatagram(
        sourcePort: UInt16,
        destinationPort: UInt16,
        payload: [UInt8]
    ) -> [UInt8] {
        let length = UInt16(8 + payload.count)
        var bytes: [UInt8] = []
        bytes += u16(sourcePort)
        bytes += u16(destinationPort)
        bytes += u16(length)
        bytes += u16(0)             // checksum
        bytes += payload
        return bytes
    }

    // MARK: - Envoltura IPv4 / IPv6

    /// Datagrama IPv4 (cabecera de 20 bytes, sin opciones). `fragmentField` son los 16 bits de
    /// flags+offset tal cual van a bytes 6-7 (para construir fragmentos no-iniciales).
    static func ipv4(
        proto: UInt8,
        source: [UInt8],
        destination: [UInt8],
        payload: [UInt8],
        fragmentField: UInt16 = 0
    ) -> Data {
        let totalLength = UInt16(20 + payload.count)
        var bytes: [UInt8] = []
        bytes.append(0x45)          // versión 4, IHL 5
        bytes.append(0x00)          // DSCP/ECN
        bytes += u16(totalLength)
        bytes += u16(0)             // identification
        bytes += u16(fragmentField)
        bytes.append(64)            // TTL
        bytes.append(proto)
        bytes += u16(0)             // checksum
        bytes += source
        bytes += destination
        bytes += payload
        return Data(bytes)
    }

    /// Datagrama IPv6 (cabecera base de 40 bytes). `nextHeader` es el primer next-header; para
    /// vectores con extension headers, `payload` debe empezar por ellas.
    static func ipv6(
        nextHeader: UInt8,
        source: [UInt8],
        destination: [UInt8],
        payload: [UInt8]
    ) -> Data {
        var bytes: [UInt8] = []
        bytes += [0x60, 0x00, 0x00, 0x00]   // versión 6, traffic class / flow label a 0
        bytes += u16(UInt16(payload.count))  // payload length
        bytes.append(nextHeader)
        bytes.append(64)                     // hop limit
        bytes += source
        bytes += destination
        bytes += payload
        return Data(bytes)
    }

    /// Extension header genérica de opciones (hop-by-hop=0, routing=43, destination=60) de 8 bytes:
    /// `nextHeader` + `hdrExtLen`=0 + 6 bytes de relleno.
    static func optionsExtensionHeader(nextHeader: UInt8) -> [UInt8] {
        [nextHeader, 0, 0, 0, 0, 0, 0, 0]
    }

    /// Fragment header IPv6 (8 bytes). `fragmentOffset` en unidades de 8 bytes; !=0 marca
    /// fragmento no-inicial.
    static func fragmentExtensionHeader(nextHeader: UInt8, fragmentOffset: UInt16, moreFragments: Bool) -> [UInt8] {
        let offsetField = (fragmentOffset << 3) | (moreFragments ? 1 : 0)
        return [nextHeader, 0] + u16(offsetField) + u32(0)
    }

    // MARK: - Vectores concretos

    static func ipv4TcpSyn() -> Data {
        ipv4(
            proto: 6,
            source: localV4,
            destination: remoteV4,
            payload: tcpHeader(
                sourcePort: 51000,
                destinationPort: 443,
                sequence: 0x12345678,
                acknowledgment: 0,
                flagsByte: 0x02,        // SYN
                window: 65535
            )
        )
    }

    static func ipv4UdpDns() -> Data {
        ipv4(
            proto: 17,
            source: localV4,
            destination: dnsV4,
            payload: udpDatagram(
                sourcePort: 53535,
                destinationPort: 53,
                payload: [0xAA, 0xBB, 0xCC, 0xDD]
            )
        )
    }

    static func ipv6Tcp() -> Data {
        ipv6(
            nextHeader: 6,
            source: localV6,
            destination: remoteV6,
            payload: tcpHeader(
                sourcePort: 50000,
                destinationPort: 443,
                sequence: 0xAABBCCDD,
                acknowledgment: 0x01020304,
                flagsByte: 0x18,        // PSH|ACK
                window: 4096
            )
        )
    }

    static func ipv6Udp() -> Data {
        ipv6(
            nextHeader: 17,
            source: localV6,
            destination: remoteV6,
            payload: udpDatagram(
                sourcePort: 33333,
                destinationPort: 443,
                payload: [0x01, 0x02, 0x03]
            )
        )
    }

    /// IPv6 con hop-by-hop options seguido de TCP.
    static func ipv6ExtHeadersTcp() -> Data {
        let tcp = tcpHeader(
            sourcePort: 40000,
            destinationPort: 8080,
            sequence: 1,
            acknowledgment: 2,
            flagsByte: 0x10,            // ACK
            window: 1024
        )
        return ipv6(
            nextHeader: 0,              // hop-by-hop options
            source: localV6,
            destination: remoteV6,
            payload: optionsExtensionHeader(nextHeader: 6) + tcp
        )
    }

    /// Fragmento IPv4 no-inicial (offset != 0): sin cabecera L4 aunque el protocolo sea TCP.
    static func ipv4NonFirstFragment() -> Data {
        ipv4(
            proto: 6,
            source: localV4,
            destination: remoteV4,
            payload: [UInt8](repeating: 0x41, count: 24),
            fragmentField: 185          // offset 185 (unidades de 8 bytes), sin flags
        )
    }

    static func ipv4Icmp() -> Data {
        ipv4(
            proto: 1,
            source: remoteV4,
            destination: localV4,
            payload: [0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01]   // echo request
        )
    }

    static func ipv6Icmpv6() -> Data {
        ipv6(
            nextHeader: 58,
            source: remoteV6,
            destination: localV6,
            payload: [0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01]
        )
    }

    /// Protocolo de transporte no soportado (ESP = 50): debe colapsar a `.other`, sin throw.
    static func ipv4Esp() -> Data {
        ipv4(
            proto: 50,
            source: remoteV4,
            destination: localV4,
            payload: [UInt8](repeating: 0x00, count: 16)
        )
    }
}
