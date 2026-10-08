import Foundation

/// Lectura de la **cabecera larga** de QUIC, que es lo único de un paquete QUIC que viaja en claro
/// y con forma fija en todas las versiones (RFC 8999 § 5.1):
///
/// ```
/// 1 byte    bit 0x80 = 1 (cabecera larga); el resto depende de la versión
/// 4 bytes   versión
/// 1 byte    longitud del Destination Connection ID, y el ID
/// 1 byte    longitud del Source Connection ID, y el ID
/// ```
///
/// Solo la llevan los primeros paquetes de una conexión (Initial, 0-RTT, Handshake, Retry); el
/// resto usa la cabecera corta, que no dice la versión. Por eso de un flujo cuyo arranque no se
/// vio no hay nada que leer, y eso no es lo mismo que no ser QUIC.
///
/// No descifra nada ni lee más allá de los dos identificadores: el nombre que el ClientHello
/// lleva dentro del Initial es otro trabajo.
public enum QUICLongHeader {

    private static let longHeaderBit: UInt8 = 0x80
    /// El «fixed bit» (RFC 9000 § 17.2), que las versiones 1 y 2 mandan siempre a 1.
    private static let fixedBit: UInt8 = 0x40
    /// Tope de un Connection ID en las versiones 1 y 2 (RFC 9000 § 17.2): quien recibe uno mayor
    /// tiene que descartar el paquete.
    private static let maxConnectionIDLength = 20
    /// Primer byte, versión y las dos longitudes: lo mínimo que tiene una cabecera larga.
    private static let minimumLength = 7

    /// La versión de la cabecera larga con la que empieza el payload de un datagrama UDP, o `nil`
    /// si no empieza por una que se reconozca.
    ///
    /// Se exige más que el bit de cabecera larga, porque un byte alto con el primer bit a 1 lo
    /// tiene media internet (RTP, sin ir más lejos): el fixed bit a 1, que los dos identificadores
    /// quepan en el datagrama y, en las versiones cuyo tope se conoce, que no lo pasen. Un
    /// paquete con el fixed bit a 0 por la extensión que permite variarlo (RFC 9287) no se lee;
    /// esa extensión solo se puede usar después de que el otro extremo la anuncie, así que el
    /// primer paquete de la conexión lo lleva siempre.
    ///
    /// Un Version Negotiation (versión `0`) da `nil`: no dice qué versión habla nadie, y sus otros
    /// siete bits son arbitrarios.
    public static func version(in payload: Data) -> QUICVersion? {
        guard payload.count >= minimumLength else { return nil }
        let start = payload.startIndex
        let first = payload[start]
        guard first & longHeaderBit != 0, first & fixedBit != 0 else { return nil }

        let raw = UInt32(payload[start + 1]) << 24
            | UInt32(payload[start + 2]) << 16
            | UInt32(payload[start + 3]) << 8
            | UInt32(payload[start + 4])
        guard raw != 0 else { return nil }
        let version = QUICVersion(rawValue: raw)
        let boundsConnectionIDs = version.hasKnownPacketProtection

        var index = start + 5
        // Destination y Source, en ese orden y con la misma forma.
        for _ in 0..<2 {
            guard index < payload.endIndex else { return nil }
            let length = Int(payload[index])
            if boundsConnectionIDs, length > maxConnectionIDLength { return nil }
            index += 1 + length
            guard index <= payload.endIndex else { return nil }
        }
        return version
    }
}
