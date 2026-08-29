import Foundation

/// Checksum de internet (RFC 1071): complemento a uno del sumatorio en complemento a uno de las
/// palabras de 16 bits big-endian del bloque.
///
/// Es un acumulador y no una función sobre un buffer porque los checksums de transporte se calculan
/// sobre la concatenación de una pseudo-cabecera y el segmento, y esos bytes no viven contiguos:
/// concatenarlos solo para sumarlos costaría una copia del payload en cada paquete emitido.
///
/// Solo el último bloque puede tener longitud impar sin afectar al resultado, pero el acumulador lo
/// soporta en cualquier posición: un byte suelto se guarda y se empareja con el primero del bloque
/// siguiente, que es lo que haría la suma sobre el buffer concatenado.
struct InternetChecksum {

    /// Suma de las palabras ya vistas, sin plegar. No puede desbordar `UInt32` en este uso: el
    /// bloque mayor posible es un datagrama IP completo (65535 B ⇒ 32768 palabras) más una
    /// pseudo-cabecera, y 32780 × 0xffff sigue por debajo de 2³².
    private var sum: UInt32 = 0

    /// Byte alto de una palabra a medias, a la espera del bloque siguiente.
    private var pendingByte: UInt8?

    init() {}

    mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        var iterator = bytes.makeIterator()

        if let pending = pendingByte, let low = iterator.next() {
            sum &+= UInt32(UInt16(pending) << 8 | UInt16(low))
            pendingByte = nil
        }

        while let high = iterator.next() {
            guard let low = iterator.next() else {
                pendingByte = high
                return
            }
            sum &+= UInt32(UInt16(high) << 8 | UInt16(low))
        }
    }

    /// Checksum de lo acumulado hasta ahora. No consume el acumulador: se puede seguir sumando
    /// después (un byte impar pendiente se rellena aquí con un cero a la derecha, como manda el
    /// RFC, pero se conserva por si llega otro bloque).
    var value: UInt16 {
        var total = sum
        if let pending = pendingByte {
            total &+= UInt32(UInt16(pending) << 8)
        }
        // Plegar los acarreos hasta que quepan en 16 bits. Dos vueltas bastan para cualquier
        // `UInt32`, pero el bucle lo hace evidente sin depender de esa cuenta.
        while total >> 16 != 0 {
            total = (total & 0xffff) &+ (total >> 16)
        }
        return ~UInt16(truncatingIfNeeded: total)
    }
}
