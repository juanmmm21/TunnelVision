import Foundation

/// Parser puro y síncrono de datagramas IP (v4/v6) + TCP/UDP.
///
/// No copia el payload: solo lee campos y calcula rangos sobre el buffer original. Todos los
/// offsets y `payloadRange` son 0-based respecto al `Data` que se le pasa (equivalente a un
/// registro `LINKTYPE_RAW`). Diseñado para el hot path de la extensión: sin estado, sin heap
/// más allá de los pequeños value types del resultado (las dos `IPAddress`).
///
/// Política de errores:
/// - Corrupción estructural (demasiado corto, longitud de cabecera imposible) ⇒ lanza
///   `PacketParseError`; el read loop la cuenta como paquete malformado y lo descarta.
/// - Protocolo de transporte no soportado (ICMP, etc.) o fragmento no-inicial ⇒ **no** lanza:
///   devuelve `ParsedPacket` con `tcp == nil`, `udp == nil` y `flowKey` con puertos 0, para que
///   el caller lo registre como metadato y haga passthrough sin ruido de errores.
public enum PacketParser {

    /// Parsea un datagrama IP.
    ///
    /// - Parameter protocolFamily: `AF_INET`/`AF_INET6` que aporta `packetFlow` como pista.
    ///   Si no coincide con el nibble de versión del contenido, **gana el contenido**: el nibble
    ///   es la fuente de verdad, la pista solo documenta el origen del dato.
    public static func parse(_ packet: Data, protocolFamily: Int32) throws -> ParsedPacket {
        // `withUnsafeBytes` normaliza a un buffer 0-based aunque `packet` sea un slice, así que
        // todos los offsets internos son directos. Con `count == 0` no se llega a desreferenciar.
        try packet.withUnsafeBytes { raw in
            try parse(raw, protocolFamily: protocolFamily)
        }
    }

    // MARK: - Despacho por versión

    private static func parse(_ raw: UnsafeRawBufferPointer, protocolFamily: Int32) throws -> ParsedPacket {
        guard raw.count >= 1 else { throw PacketParseError.tooShort(expected: 1, got: raw.count) }
        let versionNibble = raw[0] >> 4
        switch versionNibble {
        case 4: return try parseIPv4(raw)
        case 6: return try parseIPv6(raw)
        default: throw PacketParseError.unsupportedVersion(versionNibble)
        }
    }

    // MARK: - IPv4 (RFC 791)

    private static func parseIPv4(_ raw: UnsafeRawBufferPointer) throws -> ParsedPacket {
        guard raw.count >= 20 else { throw PacketParseError.tooShort(expected: 20, got: raw.count) }

        let ihlWords = Int(raw[0] & 0x0f)
        let headerLength = ihlWords * 4
        guard headerLength >= 20, headerLength <= raw.count else { throw PacketParseError.badHeaderLength }

        let rawProtocol = raw[9]
        let proto = IPProtocolNumber(wireValue: rawProtocol)
        let source = IPAddress(version: .v4, bytes: [UInt8](raw[12..<16]))
        let destination = IPAddress(version: .v4, bytes: [UInt8](raw[16..<20]))

        let totalLength = Int(readU16BE(raw, 2))
        // Un fragmento sin el primer fragmento (offset != 0) no lleva cabecera L4: sus bytes son
        // continuación del payload, no un segmento TCP/UDP. Se marca L4 ausente.
        let flagsAndFragment = readU16BE(raw, 6)
        let isNonFirstFragment = (flagsAndFragment & 0x1fff) != 0

        let l4Start = headerLength
        let l4End = clampedPayloadEnd(declared: totalLength, headerEnd: l4Start, bufferCount: raw.count)

        return try makeParsed(
            raw: raw,
            version: .v4,
            proto: proto,
            rawProtocol: rawProtocol,
            source: source,
            destination: destination,
            totalLength: totalLength,
            l4Start: l4Start,
            l4End: l4End,
            hasL4: !isNonFirstFragment
        )
    }

    // MARK: - IPv6 (RFC 8200)

    private static func parseIPv6(_ raw: UnsafeRawBufferPointer) throws -> ParsedPacket {
        guard raw.count >= 40 else { throw PacketParseError.tooShort(expected: 40, got: raw.count) }

        let payloadLength = Int(readU16BE(raw, 4))
        let source = IPAddress(version: .v6, bytes: [UInt8](raw[8..<24]))
        let destination = IPAddress(version: .v6, bytes: [UInt8](raw[24..<40]))
        let declaredEnd = 40 + payloadLength

        // Recorre la cadena de next-header saltando extension headers hasta dar con un protocolo
        // de transporte o uno desconocido. Acotado para no colgarse ante cadenas maliciosas.
        var offset = 40
        var nextHeader = raw[6]
        var isNonFirstFragment = false
        var hops = 0
        let maxExtensionHeaders = 16

        walk: while true {
            switch nextHeader {
            case 0, 43, 60:  // hop-by-hop, routing, destination options
                guard offset + 2 <= raw.count else { throw PacketParseError.truncatedL4 }
                let hdrExtLen = Int(raw[offset + 1])
                nextHeader = raw[offset]
                offset += (hdrExtLen + 1) * 8
            case 44:  // fragment header: 8 bytes fijos
                guard offset + 8 <= raw.count else { throw PacketParseError.truncatedL4 }
                if (readU16BE(raw, offset + 2) >> 3) != 0 { isNonFirstFragment = true }
                nextHeader = raw[offset]
                offset += 8
                // Solo el primer fragmento porta la cabecera de transporte; en los demás, lo que
                // sigue es payload, así que se deja de recorrer.
                if isNonFirstFragment { break walk }
            default:
                break walk
            }
            hops += 1
            guard hops <= maxExtensionHeaders else { throw PacketParseError.badHeaderLength }
            guard offset <= raw.count else { throw PacketParseError.truncatedL4 }
        }

        let proto = IPProtocolNumber(wireValue: nextHeader)
        let l4End = clampedPayloadEnd(declared: declaredEnd, headerEnd: offset, bufferCount: raw.count)

        return try makeParsed(
            raw: raw,
            version: .v6,
            proto: proto,
            rawProtocol: nextHeader,
            source: source,
            destination: destination,
            totalLength: declaredEnd,
            l4Start: offset,
            l4End: l4End,
            hasL4: !isNonFirstFragment
        )
    }

    // MARK: - Ensamblado común + L4

    private static func makeParsed(
        raw: UnsafeRawBufferPointer,
        version: IPVersion,
        proto: IPProtocolNumber,
        rawProtocol: UInt8,
        source: IPAddress,
        destination: IPAddress,
        totalLength: Int,
        l4Start: Int,
        l4End: Int,
        hasL4: Bool
    ) throws -> ParsedPacket {
        let ip = IPHeader(
            version: version,
            source: source,
            destination: destination,
            proto: proto,
            rawProtocol: rawProtocol,
            payloadRange: l4Start..<l4End,
            totalLength: totalLength
        )

        var tcp: TCPHeader?
        var udp: UDPHeader?
        var sourcePort: UInt16 = 0
        var destinationPort: UInt16 = 0

        if hasL4 {
            switch proto {
            case .tcp:
                let header = try parseTCP(raw, start: l4Start, end: l4End)
                tcp = header
                sourcePort = header.sourcePort
                destinationPort = header.destinationPort
            case .udp:
                let header = try parseUDP(raw, start: l4Start, end: l4End)
                udp = header
                sourcePort = header.sourcePort
                destinationPort = header.destinationPort
            case .icmp, .icmpv6, .other:
                break  // sin puertos; passthrough como metadato
            }
        }

        let sourceEndpoint = IPEndpoint(address: source, port: sourcePort)
        let destinationEndpoint = IPEndpoint(address: destination, port: destinationPort)
        let flowKey = FlowKey(proto: proto, source: sourceEndpoint, destination: destinationEndpoint)

        return ParsedPacket(
            ip: ip,
            tcp: tcp,
            udp: udp,
            flowKey: flowKey,
            source: sourceEndpoint,
            destination: destinationEndpoint
        )
    }

    // MARK: - TCP (RFC 9293)

    private static func parseTCP(_ raw: UnsafeRawBufferPointer, start: Int, end: Int) throws -> TCPHeader {
        let available = end - start
        guard available >= 20 else { throw PacketParseError.truncatedL4 }

        let dataOffsetWords = Int(raw[start + 12] >> 4)
        let headerLength = dataOffsetWords * 4
        guard headerLength >= 20 else { throw PacketParseError.badHeaderLength }
        guard headerLength <= available else { throw PacketParseError.truncatedL4 }

        // Bits 0..5 del byte de flags mapean 1:1 a `TCPFlags` (FIN,SYN,RST,PSH,ACK,URG); ECE/CWR
        // (bits 6-7) no se modelan y se descartan con la máscara.
        let flags = TCPFlags(rawValue: raw[start + 13] & 0x3f)

        return TCPHeader(
            sourcePort: readU16BE(raw, start + 0),
            destinationPort: readU16BE(raw, start + 2),
            sequence: readU32BE(raw, start + 4),
            acknowledgment: readU32BE(raw, start + 8),
            flags: flags,
            windowSize: readU16BE(raw, start + 14),
            dataOffsetBytes: headerLength,
            payloadRange: (start + headerLength)..<end
        )
    }

    // MARK: - UDP (RFC 768)

    private static func parseUDP(_ raw: UnsafeRawBufferPointer, start: Int, end: Int) throws -> UDPHeader {
        let available = end - start
        guard available >= 8 else { throw PacketParseError.truncatedL4 }

        return UDPHeader(
            sourcePort: readU16BE(raw, start + 0),
            destinationPort: readU16BE(raw, start + 2),
            length: readU16BE(raw, start + 4),
            payloadRange: (start + 8)..<end
        )
    }

    // MARK: - Utilidades

    /// Acota el final del payload L4 al buffer real. `declared` (total length IPv4 / 40+payload
    /// length IPv6) puede mentir: si cae fuera de `[headerEnd, bufferCount]`, se usa lo que de
    /// verdad hay. Garantiza `headerEnd <= resultado <= bufferCount`, así que el rango nunca
    /// queda invertido.
    private static func clampedPayloadEnd(declared: Int, headerEnd: Int, bufferCount: Int) -> Int {
        let cappedHeaderEnd = min(headerEnd, bufferCount)
        guard declared >= cappedHeaderEnd, declared <= bufferCount else { return bufferCount }
        return declared
    }

    @inline(__always)
    private static func readU16BE(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        (UInt16(raw[offset]) << 8) | UInt16(raw[offset + 1])
    }

    @inline(__always)
    private static func readU32BE(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        (UInt32(raw[offset]) << 24)
            | (UInt32(raw[offset + 1]) << 16)
            | (UInt32(raw[offset + 2]) << 8)
            | UInt32(raw[offset + 3])
    }
}
