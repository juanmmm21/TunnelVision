import Foundation

/// El entero de longitud variable de QUIC (RFC 9000 § 16): los dos bits altos del primer byte
/// dicen cuántos bytes ocupa (1, 2, 4 u 8) y el resto es el valor, en orden de red.
public enum QUICVarint {

    /// Lee un entero en `index` y deja `index` detrás de él, o devuelve `nil` sin moverlo si no
    /// cabe entero en `data`.
    ///
    /// No exige la codificación más corta: la RFC la pide solo para el tipo de un frame, y un
    /// observador no es quien para descartar un paquete que su destinatario va a aceptar.
    public static func read(from data: Data, at index: inout Data.Index) -> UInt64? {
        guard index >= data.startIndex, index < data.endIndex else { return nil }
        let first = data[index]
        let length = 1 << Int(first >> 6)
        guard data.endIndex - index >= length else { return nil }

        var value = UInt64(first & 0x3f)
        for offset in 1..<length {
            value = value << 8 | UInt64(data[index + offset])
        }
        index += length
        return value
    }
}
