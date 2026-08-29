import Foundation

/// Emisor puro y síncrono de datagramas IP (v4/v6) + TCP/UDP: la contraparte del `PacketParser`.
///
/// El relay (M8) recibe del servidor real bytes de transporte, no datagramas: para devolvérselos al
/// dispositivo por `packetFlow.writePackets` hay que reconstruir el datagrama entero — cabeceras IP
/// y L4, con sus checksums, en el sentido invertido. Eso es esto, y vive junto al parser y no en
/// `Relay` porque es la misma capa: serializar IP es simétrico a parsearla, los tests de round-trip
/// tienen sentido juntos, y así quien necesite emitir un datagrama (p. ej. inyectar un RST) no
/// arrastra la dependencia del relay entero.
///
/// Está en `Shared` desde M11 porque dejó de tener un solo consumidor: además del relay lo usa
/// `Shared/Fixtures` para construir los datagramas de una captura sintética, de modo que los bytes
/// que la app enseña en Simulator sean paquetes IP de verdad —parseables por el `PacketParser` de al
/// lado y por `tcpdump`— y no ruido con pinta de serlo.
///
/// El resultado es un datagrama crudo equivalente a un registro `LINKTYPE_RAW`, listo para
/// `writePackets` (que quiere exactamente eso: sin cabecera de enlace).
///
/// Lo que este emisor **no** hace, a propósito:
/// - **No fragmenta.** Si el datagrama no cabe en el campo de longitud, lanza; segmentar según la
///   MTU es cosa de quien conoce el flujo, no de quien serializa bytes.
/// - **No emite opciones** IP ni TCP: no hay caso de uso que las necesite y cada opción es superficie
///   de bug en el checksum. Las cabeceras son siempre 20 B (IPv4), 40 B (IPv6) y 20 B (TCP).
public enum PacketEmitter {

    public static let ipv4HeaderLength = 20
    public static let ipv6HeaderLength = 40
    public static let tcpHeaderLength = 20
    public static let udpHeaderLength = 8

    /// Hop limit / TTL de los datagramas emitidos. 64 es el valor por defecto habitual; para un
    /// paquete reinyectado, que solo tiene que subir por la pila local del dispositivo, sobra.
    private static let defaultHopLimit: UInt8 = 64

    /// El campo de longitud de las cabeceras (total length en IPv4, payload length en IPv6, length
    /// en UDP) es de 16 bits: nada de lo que se emita puede superarlo.
    private static let lengthFieldLimit = Int(UInt16.max)

    // MARK: - TCP (RFC 9293)

    /// Serializa un segmento TCP dentro de su datagrama IP.
    ///
    /// `flags` se enmascara a los 6 bits que modela `TCPFlags` (FIN..URG): ECE/CWR no se modelan, y
    /// emitirlos a partir de un `rawValue` con bits altos sueltos sería anunciar un ECN que no
    /// implementamos.
    public static func tcp(
        source: IPEndpoint,
        destination: IPEndpoint,
        sequence: UInt32,
        acknowledgment: UInt32,
        flags: TCPFlags,
        windowSize: UInt16,
        payload: Data = Data()
    ) throws -> Data {
        let version = try commonVersion(source: source, destination: destination)

        var segment = [UInt8]()
        segment.reserveCapacity(tcpHeaderLength + payload.count)
        segment += u16(source.port)
        segment += u16(destination.port)
        segment += u32(sequence)
        segment += u32(acknowledgment)
        segment.append(0x50)                    // data offset = 5 palabras (20 B), reservados a 0
        segment.append(flags.rawValue & 0x3f)
        segment += u16(windowSize)
        segment += u16(0)                       // checksum: se rellena abajo, con este campo a cero
        segment += u16(0)                       // urgent pointer: no emitimos datos urgentes
        segment += payload

        try checkLength(segment: segment.count, version: version)

        let checksum = transportChecksum(
            segment: segment,
            source: source.address,
            destination: destination.address,
            proto: IPProtocolNumber.tcp.rawValue
        )
        // Un checksum TCP calculado a cero es legal y se transmite tal cual (a diferencia de UDP).
        writeU16(checksum, into: &segment, at: 16)

        return wrap(segment: segment, source: source.address, destination: destination.address, proto: IPProtocolNumber.tcp.rawValue, version: version)
    }

    // MARK: - UDP (RFC 768)

    /// Serializa un datagrama UDP dentro de su datagrama IP.
    public static func udp(
        source: IPEndpoint,
        destination: IPEndpoint,
        payload: Data
    ) throws -> Data {
        let version = try commonVersion(source: source, destination: destination)

        let length = udpHeaderLength + payload.count
        guard length <= lengthFieldLimit else {
            throw PacketEmitError.datagramTooLarge(byteCount: length, limit: lengthFieldLimit)
        }

        var segment = [UInt8]()
        segment.reserveCapacity(length)
        segment += u16(source.port)
        segment += u16(destination.port)
        segment += u16(UInt16(length))
        segment += u16(0)                       // checksum: se rellena abajo, con este campo a cero
        segment += payload

        try checkLength(segment: segment.count, version: version)

        let checksum = transportChecksum(
            segment: segment,
            source: source.address,
            destination: destination.address,
            proto: IPProtocolNumber.udp.rawValue
        )
        // RFC 768: un checksum calculado a cero se transmite como todo unos, porque el cero está
        // reservado para "sin checksum". Ambos valores son el mismo número en complemento a uno, así
        // que el receptor valida igual. En IPv6 (RFC 8200 §8.1) el checksum es obligatorio y el cero
        // no es una opción, con lo que la regla vale para las dos familias.
        writeU16(checksum == 0 ? 0xffff : checksum, into: &segment, at: 6)

        return wrap(segment: segment, source: source.address, destination: destination.address, proto: IPProtocolNumber.udp.rawValue, version: version)
    }

    // MARK: - Capa superior sin modelar

    /// Serializa un payload **opaco** de capa superior dentro de su datagrama IP.
    ///
    /// Existe para los protocolos que este emisor no modela —ICMP, ICMPv6 o cualquier otro número—:
    /// la cabecera IP se construye igual, y lo que va detrás son bytes que aquí nadie interpreta. Es
    /// la mitad que le faltaba para cubrir lo mismo que el parser, que sí acepta esos protocolos (sin
    /// puertos, como metadato) y por tanto puede crear flujos que hasta ahora no se sabían emitir.
    ///
    /// **El checksum de la capa superior, si lo lleva, es de quien compone el payload.** No se calcula
    /// aquí porque su forma no es común: ICMPv4 (RFC 792) cubre solo su propio mensaje, mientras que
    /// ICMPv6 (RFC 4443 §2.3) cubre además una pseudo-cabecera IPv6. Adivinar cuál toca a partir del
    /// número de protocolo sería inventar una regla que el RFC no da.
    public static func datagram(
        source: IPAddress,
        destination: IPAddress,
        rawProtocol: UInt8,
        payload: Data
    ) throws -> Data {
        guard source.version == destination.version else {
            throw PacketEmitError.addressFamilyMismatch(
                source: source.version,
                destination: destination.version
            )
        }
        try checkLength(segment: payload.count, version: source.version)
        return wrap(
            segment: [UInt8](payload),
            source: source,
            destination: destination,
            proto: rawProtocol,
            version: source.version
        )
    }

    // MARK: - Envoltura IP

    private static func wrap(
        segment: [UInt8],
        source: IPAddress,
        destination: IPAddress,
        proto: UInt8,
        version: IPVersion
    ) -> Data {
        switch version {
        case .v4:
            return wrapIPv4(segment: segment, source: source, destination: destination, proto: proto)
        case .v6:
            return wrapIPv6(segment: segment, source: source, destination: destination, proto: proto)
        }
    }

    /// Cabecera IPv4 (RFC 791) de 20 bytes, sin opciones.
    private static func wrapIPv4(segment: [UInt8], source: IPAddress, destination: IPAddress, proto: UInt8) -> Data {
        var datagram = [UInt8]()
        datagram.reserveCapacity(ipv4HeaderLength + segment.count)
        datagram.append(0x45)                                       // versión 4, IHL 5 (sin opciones)
        datagram.append(0x00)                                       // DSCP/ECN: sin marcar
        datagram += u16(UInt16(ipv4HeaderLength + segment.count))   // total length
        // Identification a cero y DF a uno: el campo de identificación solo sirve para reensamblar
        // fragmentos, y este emisor no fragmenta nunca. DF lo dice explícitamente en vez de dejar que
        // se deduzca de un offset a cero.
        datagram += u16(0)                                          // identification
        datagram += u16(0x4000)                                     // flags: DF; fragment offset 0
        datagram.append(defaultHopLimit)                            // TTL
        datagram.append(proto)
        datagram += u16(0)                                          // checksum: se rellena abajo
        datagram += source.bytes
        datagram += destination.bytes

        // El checksum IPv4 cubre solo la cabecera, no el payload.
        var checksum = InternetChecksum()
        checksum.append(datagram)
        writeU16(checksum.value, into: &datagram, at: 10)

        datagram += segment
        return Data(datagram)
    }

    /// Cabecera IPv6 (RFC 8200) de 40 bytes. Sin extension headers y sin checksum: IPv6 lo delegó
    /// entero en la capa de transporte.
    private static func wrapIPv6(segment: [UInt8], source: IPAddress, destination: IPAddress, proto: UInt8) -> Data {
        var datagram = [UInt8]()
        datagram.reserveCapacity(ipv6HeaderLength + segment.count)
        datagram += [0x60, 0x00, 0x00, 0x00]        // versión 6; traffic class y flow label a 0
        datagram += u16(UInt16(segment.count))      // payload length (no incluye la cabecera base)
        datagram.append(proto)                      // next header
        datagram.append(defaultHopLimit)            // hop limit
        datagram += source.bytes
        datagram += destination.bytes
        datagram += segment
        return Data(datagram)
    }

    // MARK: - Checksum de transporte

    /// Checksum TCP/UDP: pseudo-cabecera + segmento completo, con el campo de checksum ya a cero.
    ///
    /// La pseudo-cabecera no viaja en el cable; existe para que el checksum de transporte cubra
    /// también las direcciones y el protocolo, y así un paquete mal entregado no pase por bueno.
    private static func transportChecksum(
        segment: [UInt8],
        source: IPAddress,
        destination: IPAddress,
        proto: UInt8
    ) -> UInt16 {
        var checksum = InternetChecksum()
        checksum.append(source.bytes)
        checksum.append(destination.bytes)

        switch source.version {
        case .v4:
            // Pseudo-cabecera IPv4 (RFC 793): zero(1) + proto(1) + longitud del segmento(2).
            checksum.append([0, proto])
            checksum.append(u16(UInt16(segment.count)))
        case .v6:
            // Pseudo-cabecera IPv6 (RFC 8200 §8.1): longitud del upper-layer(4) + zeros(3) +
            // next header(1). Ojo: la longitud es de 32 bits aquí, no de 16 como en IPv4.
            checksum.append(u32(UInt32(segment.count)))
            checksum.append([0, 0, 0, proto])
        }

        checksum.append(segment)
        return checksum.value
    }

    // MARK: - Validación

    private static func commonVersion(source: IPEndpoint, destination: IPEndpoint) throws -> IPVersion {
        guard source.address.version == destination.address.version else {
            throw PacketEmitError.addressFamilyMismatch(
                source: source.address.version,
                destination: destination.address.version
            )
        }
        return source.address.version
    }

    /// Comprueba que el datagrama cabe en el campo de longitud de su cabecera IP. El límite se mide
    /// sobre campos distintos según la familia: IPv4 cuenta cabecera + segmento, IPv6 solo el
    /// segmento (su payload length excluye la cabecera base).
    private static func checkLength(segment: Int, version: IPVersion) throws {
        let counted: Int
        switch version {
        case .v4: counted = ipv4HeaderLength + segment
        case .v6: counted = segment
        }
        guard counted <= lengthFieldLimit else {
            throw PacketEmitError.datagramTooLarge(byteCount: counted, limit: lengthFieldLimit)
        }
    }

    // MARK: - Codificación big-endian

    @inline(__always)
    private static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xff)]
    }

    @inline(__always)
    private static func u32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    @inline(__always)
    private static func writeU16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xff)
    }
}
