import SwiftUI

/// El punto de entrada de la app.
///
/// No hace nada más que crear el entorno una vez y colgar de él la escena: cualquier lógica que
/// apareciese aquí sería lógica sin test, porque `App` no se puede instanciar en el Simulator sin
/// arrancar la app entera.
@main
struct TunnelVisionApp: App {

    /// `@State` y no una constante: SwiftUI garantiza así que el entorno —y con él el controlador del
    /// túnel y el lector del feed— se cree **una sola vez** y sobreviva a los repintados de la escena.
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            // En Debug, el arranque puede pasar antes por el sembrador de capturas sintéticas (M11):
            // en Simulator la extensión no corre, así que sin él la mitad de las pantallas no tienen
            // nada que enseñar. La puerta solo se interpone si se pidió por argumento de lanzamiento;
            // en cualquier otro caso pinta la app directamente, y en Release ni existe.
            #if DEBUG
            FixtureSeedGate {
                RootView(environment: environment)
            }
            #else
            RootView(environment: environment)
            #endif
        }
    }
}
