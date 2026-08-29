import Foundation
import XCTest

/// El formateo que enseña la Dashboard. Se prueba porque es determinista **a propósito**: si algún
/// día vuelve a un formateador de Foundation, estos tests fallarán en cuanto la unidad, el separador
/// o el número de decimales dependan de la configuración regional.
final class DisplayFormatTests: XCTestCase {

    // MARK: - Volúmenes

    func testBytesBelowAThousandKeepTheirUnit() {
        XCTAssertEqual(DisplayFormat.bytes(0), "0 B")
        XCTAssertEqual(DisplayFormat.bytes(812), "812 B")
        XCTAssertEqual(DisplayFormat.bytes(999), "999 B")
    }

    func testBytesScaleToTheLargestUnitThatStaysAboveOne() {
        XCTAssertEqual(DisplayFormat.bytes(1_000), "1 KB")
        XCTAssertEqual(DisplayFormat.bytes(1_500), "1.5 KB")
        XCTAssertEqual(DisplayFormat.bytes(1_000_000), "1 MB")
        XCTAssertEqual(DisplayFormat.bytes(2_500_000_000), "2.5 GB")
    }

    /// Un decimal por debajo de 10 y ninguno por encima: es lo que evita que la anchura del texto
    /// baile mientras el contador sube.
    func testOnlySmallValuesKeepADecimal() {
        XCTAssertEqual(DisplayFormat.bytes(9_500), "9.5 KB")
        XCTAssertEqual(DisplayFormat.bytes(15_000), "15 KB")
        XCTAssertEqual(DisplayFormat.bytes(150_000), "150 KB")
    }

    /// El caso que obligó a redondear antes de decidir: 9,96 KB no puede salir como "10.0 KB", con
    /// decimal y por encima del umbral que dice no tenerlo.
    func testAValueThatRoundsUpToTenLosesItsDecimal() {
        XCTAssertEqual(DisplayFormat.bytes(9_960), "10 KB")
    }

    // MARK: - Velocidades

    func testRatesCarryTheirUnitPerSecond() {
        XCTAssertEqual(DisplayFormat.rate(bytesPerSecond: 1_536), "1.5 KB/s")
        XCTAssertEqual(DisplayFormat.rate(bytesPerSecond: 2_000_000), "2 MB/s")
    }

    /// Una velocidad imposible en pantalla es peor que un cero honesto: los valores no representables
    /// se colapsan en vez de propagarse a la etiqueta.
    func testImpossibleRatesReadAsZero() {
        XCTAssertEqual(DisplayFormat.rate(bytesPerSecond: 0), "0 B/s")
        XCTAssertEqual(DisplayFormat.rate(bytesPerSecond: -1), "0 B/s")
        XCTAssertEqual(DisplayFormat.rate(bytesPerSecond: .nan), "0 B/s")
        XCTAssertEqual(DisplayFormat.rate(bytesPerSecond: .infinity), "0 B/s")
    }

    // MARK: - Duraciones

    func testDurationsAreCutToTwoUnits() {
        XCTAssertEqual(DisplayFormat.duration(0.4), "0.4 s")
        XCTAssertEqual(DisplayFormat.duration(12), "12 s")
        XCTAssertEqual(DisplayFormat.duration(59.9), "59 s")
        XCTAssertEqual(DisplayFormat.duration(200), "3 min 20 s")
        XCTAssertEqual(DisplayFormat.duration(180), "3 min")
        XCTAssertEqual(DisplayFormat.duration(3_900), "1 h 05 min")
        XCTAssertEqual(DisplayFormat.duration(7_200), "2 h")
    }

    /// Un flujo de un solo paquete dura cero, y un reloj que se cruza puede dar una duración
    /// negativa: ninguna de las dos cosas puede acabar en la pantalla como un número raro.
    func testImpossibleDurationsReadAsZero() {
        XCTAssertEqual(DisplayFormat.duration(0), "0 s")
        XCTAssertEqual(DisplayFormat.duration(-5), "0 s")
        XCTAssertEqual(DisplayFormat.duration(.nan), "0 s")
        XCTAssertEqual(DisplayFormat.duration(.infinity), "0 s")
    }

    // MARK: - Desfases dentro de una conexión

    /// El milisegundo es el motivo de que esto no sea `duration`: los paquetes de una conexión se
    /// separan por milisegundos, y con la resolución de aquella los primeros cien saldrían todos como
    /// "0.0 s", que es tanto como no poner nada.
    func testOffsetsKeepTheirMillisecondsBelowAMinute() {
        XCTAssertEqual(DisplayFormat.offset(0.004), "0.004 s")
        XCTAssertEqual(DisplayFormat.offset(0.25), "0.250 s")
        XCTAssertEqual(DisplayFormat.offset(12.5), "12.500 s")
        XCTAssertEqual(DisplayFormat.offset(59.999), "59.999 s")
    }

    /// Pasado el minuto el milisegundo ya no dice nada, así que se delega en la duración.
    func testOffsetsAboveAMinuteReadLikeDurations() {
        XCTAssertEqual(DisplayFormat.offset(60), "1 min")
        XCTAssertEqual(DisplayFormat.offset(200), "3 min 20 s")
    }

    func testAnImpossibleOffsetReadsAsZero() {
        XCTAssertEqual(DisplayFormat.offset(0), "0.000 s")
        XCTAssertEqual(DisplayFormat.offset(-0.5), "0.000 s")
        XCTAssertEqual(DisplayFormat.offset(.nan), "0.000 s")
    }

    // MARK: - Contadores

    func testCountsGroupThousandsWithAFixedSeparator() {
        XCTAssertEqual(DisplayFormat.count(0), "0")
        XCTAssertEqual(DisplayFormat.count(999), "999")
        XCTAssertEqual(DisplayFormat.count(1_204), "1,204")
        XCTAssertEqual(DisplayFormat.count(1_000_000), "1,000,000")
        XCTAssertEqual(DisplayFormat.count(12_345_678), "12,345,678")
    }
}
