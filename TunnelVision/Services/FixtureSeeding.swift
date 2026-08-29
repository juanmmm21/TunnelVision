import Foundation
import Shared

// Debug-only como las dos mitades del sembrador que hay debajo. Aquí es además donde se decide
// **cuándo** se siembra, y esa decisión no debe existir siquiera en Release: un argumento de
// lanzamiento es lo único que separa una app normal de una que se reescribe el historial encima.
#if DEBUG

/// Qué hacer con el argumento de siembra en este arranque.
///
/// Son tres casos y no un `Bool` porque "no se ha pedido" y "se ha pedido y no se va a hacer" son
/// cosas distintas para quien lanzó la app: la segunda tiene que decirse por consola, o quien pasó el
/// argumento en un dispositivo se quedaría mirando una Timeline vacía sin saber por qué.
public enum FixtureSeedRequest: Sendable, Equatable {

    case notRequested

    case seed

    /// Pedido, pero no se corre en Simulator.
    ///
    /// El sembrador **reemplaza** lo que haya, y en un dispositivo lo que hay es la captura de verdad
    /// de su dueño: sembrar ahí borraría tráfico real para poner tráfico inventado, que es dos veces
    /// lo contrario de lo que el producto promete. Y no hace ninguna falta — la razón de ser del
    /// sembrador es que en Simulator la extensión no corre y por tanto no hay datos; en un
    /// dispositivo los escribe ella.
    case refusedOffSimulator
}

/// El argumento de lanzamiento que siembra la captura sintética, y lo que hace cuando está puesto.
///
/// Es un argumento y no un botón en la UI a propósito: un botón habría que dibujarlo, esconderlo en
/// Release y explicarlo, mientras que un argumento se pone en el scheme de Xcode y en
/// `xcrun simctl launch` sin tocar ninguna pantalla y sin poder acabar delante de un usuario.
public enum FixtureSeeding {

    /// `xcodebuild`/Xcode: *Edit Scheme → Run → Arguments*.
    /// Terminal: `xcrun simctl launch --console <device> com.juanmmm21.tunnelvision -TVSeedFixture`.
    public static let argument = "-TVSeedFixture"

    public static func request(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        isSimulator: Bool = FixtureSeeding.isRunningInSimulator
    ) -> FixtureSeedRequest {
        guard arguments.contains(argument) else { return .notRequested }
        return isSimulator ? .seed : .refusedOffSimulator
    }

    public static var isRunningInSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Genera la captura por defecto y la escribe en el contenedor compartido.
    ///
    /// `endingAt` es *ahora* porque lo que hace creíble una captura al abrirla es que lo último que
    /// enseña sea de hace un momento; la semilla sigue siendo fija, así que la captura es la misma
    /// salvo por dónde cae en el calendario.
    public static func seed(
        appGroupID: String = AppGroup.identifier,
        endingAt: Date = Date()
    ) async throws -> SeedReport {
        let seeder = try FixtureSeeder(appGroupID: appGroupID)
        return try await seeder.seed(CaptureFixture.make(.default(endingAt: endingAt)))
    }
}

#endif
