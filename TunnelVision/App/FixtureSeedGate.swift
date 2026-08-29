import SwiftUI

#if DEBUG

/// Lo que se interpone entre el arranque y las pantallas cuando se ha pedido sembrar (M11).
///
/// Es una puerta y no una tarea en paralelo porque la siembra **reemplaza** el historial: dejar que
/// las pantallas se monten mientras se escribe las pondría a leer una base de datos que se está
/// vaciando, y lo que verían es un vacío que ya no es cierto para cuando termina de dibujarse. Con la
/// puerta, cuando la app aparece los datos están.
///
/// Todo lo que decide vive fuera (`FixtureSeeding`, probado); aquí solo está el dibujo y el aviso por
/// consola, que es lo que evita que quien pasa el argumento crea que la app se ha colgado — la
/// captura por defecto son miles de paquetes y varios megabytes de `.pcap`.
struct FixtureSeedGate<Content: View>: View {

    @ViewBuilder var content: () -> Content

    /// Se decide una vez, al construir: los argumentos de lanzamiento no cambian durante la ejecución.
    private let request = FixtureSeeding.request()

    @State private var hasFinished = false

    var body: some View {
        Group {
            if request == .seed && !hasFinished {
                progress
            } else {
                content()
            }
        }
        .task {
            switch request {
            case .notRequested:
                return
            case .refusedOffSimulator:
                // Se dice en vez de callarse: quien puso el argumento en un dispositivo se quedaría
                // si no mirando su propio historial, creyendo que la siembra falló en silencio.
                print("[TunnelVision] \(FixtureSeeding.argument) ignored: seeding only runs on the Simulator.")
            case .seed:
                await seed()
            }
        }
    }

    /// La copia de esta pantalla **no pasa por el catálogo**, y no por descuido: es un diagnóstico
    /// para quien lanza la app desde Xcode, de la misma familia que el identificador de App Group que
    /// la pantalla de capturas enseña en un fallo. `Text(verbatim:)` es lo que impide que el
    /// extractor la meta entre las claves del producto.
    private var progress: some View {
        ProgressView {
            Text(verbatim: "Seeding synthetic capture…")
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func seed() async {
        let started = Date()
        do {
            let report = try await FixtureSeeding.seed()
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            print("[TunnelVision] \(report.summary) Took \(elapsed)s.")
        } catch {
            print("[TunnelVision] Seeding failed: \(error)")
        }
        hasFinished = true
    }
}

#endif
