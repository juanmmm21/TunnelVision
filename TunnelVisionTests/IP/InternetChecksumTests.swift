import Foundation
import XCTest
// `InternetChecksum` es interno a `Shared`: lo usan el emisor y el parser de al lado, y nadie fuera
// del framework tiene que sumar checksums. Se prueba con `@testable` en vez de hacerlo público solo
// para el test, que es la misma decisión (y la misma línea) que toman los tests del codificador DER.
@testable import Shared

/// Tests del acumulador de checksum (RFC 1071). Los dos vectores golden vienen de fuentes externas
/// (el ejemplo del propio RFC 1071 y la cabecera IPv4 de ejemplo del RFC 1624), no de ejecutar esta
/// implementación: son el ancla que impide que el resto de los tests del emisor se confirmen a sí
/// mismos, ya que ellos sí usan este tipo indirectamente.
final class InternetChecksumTests: XCTestCase {

    /// RFC 1071 §3: la secuencia 00 01 f2 03 f4 f5 f6 f7 tiene checksum 0x220d.
    private let rfc1071Block: [UInt8] = [0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]
    private let rfc1071Checksum: UInt16 = 0x220d

    func testMatchesRFC1071Vector() {
        var checksum = InternetChecksum()
        checksum.append(rfc1071Block)
        XCTAssertEqual(checksum.value, rfc1071Checksum)
    }

    /// Cabecera IPv4 de ejemplo del RFC 1624 §3, con el campo de checksum a cero: su checksum es
    /// 0xb861. Cubre el plegado de acarreos, que el vector del RFC 1071 apenas ejercita.
    func testMatchesRFC1624IPv4HeaderVector() {
        let header: [UInt8] = [
            0x45, 0x00, 0x00, 0x73,
            0x00, 0x00, 0x40, 0x00,
            0x40, 0x11, 0x00, 0x00,     // TTL, proto, checksum a cero
            0xc0, 0xa8, 0x00, 0x01,
            0xc0, 0xa8, 0x00, 0xc7,
        ]
        var checksum = InternetChecksum()
        checksum.append(header)
        XCTAssertEqual(checksum.value, 0xb861)
    }

    /// La suma sobre bloques troceados debe ser idéntica a la del buffer entero, incluso partiendo
    /// por un índice impar: es justo el caso de la pseudo-cabecera + segmento, que nunca se
    /// concatenan en memoria.
    func testSplittingBlocksAtAnOddIndexYieldsTheSameValue() {
        for splitIndex in 0...rfc1071Block.count {
            var checksum = InternetChecksum()
            checksum.append(rfc1071Block[0..<splitIndex])
            checksum.append(rfc1071Block[splitIndex...])
            XCTAssertEqual(checksum.value, rfc1071Checksum, "split en \(splitIndex)")
        }
    }

    /// Un bloque de longitud impar se rellena con un cero a la derecha (RFC 1071), y ese relleno no
    /// debe contaminar un bloque posterior: consultar `value` no consume el byte pendiente.
    func testOddBlockPadsWithZeroWithoutConsumingThePendingByte() {
        var checksum = InternetChecksum()
        checksum.append([0x01, 0x02, 0x03])

        // 0x0102 + 0x0300 = 0x0402 con el relleno.
        XCTAssertEqual(checksum.value, ~UInt16(0x0402))

        // El 0x03 sigue pendiente: al llegar otro bloque se empareja con su primer byte.
        checksum.append([0x04])
        XCTAssertEqual(checksum.value, ~UInt16(0x0102 + 0x0304))
    }

    func testEmptyInputChecksumIsAllOnes() {
        var checksum = InternetChecksum()
        checksum.append([UInt8]())
        XCTAssertEqual(checksum.value, 0xffff)
    }

    /// Propiedad de verificación del RFC 1071: sumar un bloque junto a su propio checksum da cero.
    /// Es lo que hace el receptor, y lo que los tests del emisor usan para validar los datagramas.
    func testBlockPlusItsChecksumVerifiesToZero() {
        var checksum = InternetChecksum()
        checksum.append(rfc1071Block)
        checksum.append([UInt8(rfc1071Checksum >> 8), UInt8(rfc1071Checksum & 0xff)])
        XCTAssertEqual(checksum.value, 0)
    }

    /// El acarreo tiene que plegarse más de una vez: 0xffff repetido muchas veces desborda los 16
    /// bits en cada suma.
    func testFoldsRepeatedCarries() {
        var checksum = InternetChecksum()
        checksum.append([UInt8](repeating: 0xff, count: 1000))
        // La suma en complemento a uno de N veces 0xffff es 0xffff (0xffff es el cero negativo).
        XCTAssertEqual(checksum.value, 0)
    }
}
