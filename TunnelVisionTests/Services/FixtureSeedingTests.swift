import Foundation
import XCTest
import Shared

/// Tests de la decisión del arranque (M11): cuándo se siembra la captura sintética.
///
/// La siembra en sí está probada en `FixtureSeederTests`, contra rutas temporales. Lo que se afirma
/// aquí es lo único que decide esta capa —si el argumento se atiende, se ignora o se rechaza— y se
/// afirma en puro, porque hacerlo de verdad significaría escribir en el contenedor compartido de la
/// máquina que corre los tests, borrando de paso cualquier captura sembrada que hubiera.
final class FixtureSeedingTests: XCTestCase {

    func testWithoutTheArgumentNothingIsSeeded() {
        XCTAssertEqual(
            FixtureSeeding.request(arguments: ["/path/TunnelVision.app"], isSimulator: true),
            .notRequested
        )
        XCTAssertEqual(
            FixtureSeeding.request(arguments: [], isSimulator: true),
            .notRequested
        )
    }

    func testTheArgumentSeedsOnTheSimulator() {
        XCTAssertEqual(
            FixtureSeeding.request(
                arguments: ["/path/TunnelVision.app", FixtureSeeding.argument],
                isSimulator: true
            ),
            .seed
        )
    }

    /// El sembrador **reemplaza** lo que haya, y en un dispositivo lo que hay es la captura de verdad
    /// de su dueño: sembrar ahí borraría tráfico real para poner tráfico inventado. Y no hace falta,
    /// porque allí sí corre la extensión, que es la que escribe. El caso es propio y no un
    /// `notRequested` disfrazado justamente para poder decirlo por consola: quien pasó el argumento
    /// tiene que enterarse de que no se hizo.
    func testTheArgumentIsRefusedOffTheSimulator() {
        XCTAssertEqual(
            FixtureSeeding.request(
                arguments: ["/path/TunnelVision.app", FixtureSeeding.argument],
                isSimulator: false
            ),
            .refusedOffSimulator
        )
    }

    /// Un argumento que se parece no es el argumento. Se compara la palabra entera y no un prefijo,
    /// porque el listado de un lanzamiento lleva también los de Xcode y los del propio sistema.
    func testOnlyTheExactArgumentCounts() {
        for lookalike in ["-TVSeedFixtures", "TVSeedFixture", "--TVSeedFixture", "-tvseedfixture"] {
            XCTAssertEqual(
                FixtureSeeding.request(arguments: [lookalike], isSimulator: true),
                .notRequested,
                "«\(lookalike)» no es \(FixtureSeeding.argument)"
            )
        }
    }

    /// La suite corre en Simulator, así que la lectura del entorno de compilación tiene que decirlo.
    /// Sin esto, el `request()` de producción —el que llama la puerta del arranque— podría estar
    /// contestando siempre `refusedOffSimulator` y ningún otro test se enteraría.
    func testTheSimulatorIsDetected() {
        XCTAssertTrue(FixtureSeeding.isRunningInSimulator)
    }
}
