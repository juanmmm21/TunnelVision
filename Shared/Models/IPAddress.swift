import Foundation

/// IP cruda; evita depender de `Network.IPv4Address` en el modelo base.
///
/// Se guarda en su forma binaria (4 bytes para v4, 16 para v6) porque esta representación
/// cruza el límite entre procesos (ring buffer, pcap) y acaba en la base de datos, donde el
/// layout importa. `description` produce el texto canónico para la UI.
public struct IPAddress: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let version: IPVersion
    public let bytes: [UInt8]        // 4 para v4, 16 para v6

    /// Precondición: `bytes.count` coincide con la longitud de la familia (`version`).
    /// Es un error de programación construir una IP con un número de bytes incoherente.
    public init(version: IPVersion, bytes: [UInt8]) {
        precondition(
            bytes.count == version.addressByteCount,
            "IPAddress \(version) requiere \(version.addressByteCount) bytes, recibidos \(bytes.count)"
        )
        self.version = version
        self.bytes = bytes
    }

    /// Construye una dirección desde su forma de presentación (`"192.0.2.1"`, `"2001:db8::1"`), o
    /// `nil` si el texto no es una IP literal.
    ///
    /// Se usa `inet_pton` y no un parser propio ni `Network.IPv4Address`: es la contraparte exacta
    /// del `inet_ntop` que produce estos textos y no arrastra `Network` al modelo base.
    ///
    /// **La zona se rechaza aquí y no en `inet_pton`**, porque `inet_pton` no la rechaza: en Darwin,
    /// `fe80::1%en0` no falla — devuelve `fe80:e::1`, o sea que se traga el `%en0` y produce una
    /// dirección **distinta y silenciosamente equivocada**. Una dirección cuyo alcance es un interfaz
    /// concreto no significa nada sin él, así que se descarta entera en vez de aceptar la que salga.
    public init?(parsing string: String) {
        guard !string.contains("%") else { return nil }

        var v4 = in_addr()
        if string.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            self.init(version: .v4, bytes: withUnsafeBytes(of: &v4.s_addr) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if string.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            self.init(version: .v6, bytes: withUnsafeBytes(of: &v6) { Array($0) })
            return
        }
        return nil
    }

    /// Orden total y estable sobre direcciones: primero por familia, luego lexicográfico
    /// sobre los bytes. Base de la canonicalización de `FlowKey`.
    public static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        if lhs.version != rhs.version {
            return lhs.version.rawValue < rhs.version.rawValue
        }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public var description: String {
        switch version {
        case .v4:
            return Self.formatIPv4(bytes)
        case .v6:
            return Self.formatIPv6(bytes)
        }
    }

    private static func formatIPv4(_ bytes: [UInt8]) -> String {
        // Defensivo ante un valor decodificado con longitud inesperada: no reventar la UI.
        guard bytes.count == 4 else { return hexFallback(bytes) }
        return bytes.map(String.init).joined(separator: ".")
    }

    /// Formatea IPv6 según RFC 5952: hex en minúsculas, sin ceros a la izquierda por grupo,
    /// y colapsando con `::` la secuencia más larga de grupos a cero (la más a la izquierda
    /// en caso de empate; solo si cubre 2+ grupos).
    private static func formatIPv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return hexFallback(bytes) }

        var groups = [UInt16](repeating: 0, count: 8)
        for i in 0..<8 {
            groups[i] = (UInt16(bytes[i * 2]) << 8) | UInt16(bytes[i * 2 + 1])
        }

        // Localiza la secuencia de ceros más larga (mínimo 2 grupos) para comprimir.
        var bestStart = -1
        var bestLength = 0
        var currentStart = -1
        var currentLength = 0
        for i in 0..<8 {
            if groups[i] == 0 {
                if currentStart == -1 { currentStart = i }
                currentLength += 1
                if currentLength > bestLength {
                    bestLength = currentLength
                    bestStart = currentStart
                }
            } else {
                currentStart = -1
                currentLength = 0
            }
        }
        if bestLength < 2 {
            bestStart = -1
            bestLength = 0
        }

        var parts: [String] = []
        var i = 0
        while i < 8 {
            if i == bestStart {
                // Marcador que se traduce en el "::" al unir con ":".
                parts.append("")
                if bestStart == 0 { parts.append("") } // prefijo "::" cuando empieza en el grupo 0
                i += bestLength
                if i == 8 { parts.append("") }         // sufijo "::" cuando llega al final
            } else {
                parts.append(String(groups[i], radix: 16))
                i += 1
            }
        }
        return parts.joined(separator: ":")
    }

    private static func hexFallback(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
