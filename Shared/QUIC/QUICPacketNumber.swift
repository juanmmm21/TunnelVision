import Foundation

/// El número de paquete de QUIC viaja **truncado** a entre uno y cuatro bytes (RFC 9000 § 17.1):
/// quien lo recibe lo completa con el mayor que lleva visto. Hace falta entero porque es parte del
/// nonce con el que se abre el paquete.
public enum QUICPacketNumber {

    /// El mayor número de paquete que existe: 2^62 − 1 (RFC 9000 § 12.3).
    public static let maximum: UInt64 = (1 << 62) - 1

    /// El número de paquete completo, según el algoritmo de la RFC 9000 (Apéndice A.3): el valor
    /// más cercano al siguiente esperado cuyos bytes bajos son los que llegaron.
    ///
    /// - Parameters:
    ///   - truncated: el campo tal como viaja, ya sin protección de cabecera.
    ///   - byteCount: cuántos bytes ocupaba, de 1 a 4. Fuera de ese rango devuelve `nil`.
    ///   - largestProcessed: el mayor ya abierto en este espacio de numeración, o `nil` si este es
    ///     el primero — entonces el esperado es el 0, que es donde empieza cada espacio (§ 12.3).
    public static func decode(truncated: UInt64, byteCount: Int, largestProcessed: UInt64?) -> UInt64? {
        guard (1...4).contains(byteCount) else { return nil }
        let window: UInt64 = 1 << UInt64(byteCount * 8)
        let halfWindow = window / 2
        let mask = window - 1
        guard truncated <= mask else { return nil }

        let expected: UInt64
        if let largestProcessed {
            guard largestProcessed < maximum else { return nil }
            expected = largestProcessed + 1
        } else {
            expected = 0
        }

        let candidate = (expected & ~mask) | truncated
        // Las comparaciones van sumando al otro lado para no restar por debajo de cero.
        if candidate + halfWindow <= expected, candidate < (1 << 62) - window {
            return candidate + window
        }
        if candidate > expected + halfWindow, candidate >= window {
            return candidate - window
        }
        return candidate
    }
}
