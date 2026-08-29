import SwiftUI

/// Las pestañas del mapa de navegación de `docs/ux/screens.md`.
///
/// Solo están las que tienen pantalla: una pestaña que no lleva a ninguna parte es peor que no
/// tenerla. El flujo guiado de la CA no es una pestaña a propósito: se abre desde Settings, que es
/// donde vive el interruptor que gobierna, y se cierra volviendo ahí.
enum RootTab: Hashable {
    case dashboard
    case timeline
    case captures
    case settings
}

/// La escena principal: el `TabView` que contiene las pantallas.
struct RootView: View {

    let environment: AppEnvironment

    @State private var selection: RootTab = .dashboard

    /// Volver a primer plano es cuando el usuario puede haber estado justo en los Ajustes de iOS
    /// retirando la confianza del certificado, así que es cuando hay que volver a preguntar.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            DashboardView(
                controller: environment.tunnelController,
                viewModel: environment.dashboard
            )
            // La copia se muda pantalla a pantalla: tres pestañas ya salen del catálogo y solo la de
            // Ajustes sigue con su literal (y con el inglés de clave) hasta que le toque.
            .tabItem {
                Label(DashboardPresentation.tabTitle, systemImage: "chart.line.uptrend.xyaxis")
            }
            .tag(RootTab.dashboard)

            TimelineView(
                viewModel: environment.timeline,
                library: environment.captureLibrary,
                plaintext: environment.plaintextLibrary
            )
                .tabItem {
                    Label(TimelinePresentation.tabTitle, systemImage: "clock.arrow.circlepath")
                }
                .tag(RootTab.timeline)

            CapturesView(
                controller: environment.tunnelController,
                viewModel: environment.captures
            )
            .tabItem {
                Label(CapturesPresentation.tabTitle, systemImage: "externaldrive")
            }
            .tag(RootTab.captures)

            SettingsView(
                controller: environment.tunnelController,
                viewModel: environment.settings,
                intro: environment.intro,
                certificateSetup: environment.certificateSetup,
                diagnostics: environment.diagnostics
            )
            .tabItem {
                Label(SettingsPresentation.tabTitle, systemImage: "gearshape")
            }
            .tag(RootTab.settings)
        }
        // El intro tapa la app entera y no una pestaña: mientras se explica qué es esto, no hay nada
        // detrás que se pueda tocar por error (M10, `docs/ux/onboarding-and-consent.md`).
        .fullScreenCover(
            isPresented: Binding(
                get: { environment.intro.isPresented },
                // Cerrarlo desde el sistema es cerrarlo sin pedir nada, que es lo mismo que la salida
                // de la tarjeta. `skip()` es idempotente, así que llegar aquí después de que el view
                // model ya lo haya cerrado no vuelve a terminar nada.
                set: { isPresented in if !isPresented { environment.intro.skip() } }
            )
        ) {
            IntroView(viewModel: environment.intro)
        }
        .task {
            environment.intro.prepare()
            // La inspección se apaga sola si el sistema ha dejado de aceptar la CA. Va en la raíz y
            // no en la pantalla de Ajustes porque el ajuste gobierna el tráfico del dispositivo
            // entero: esperar a que el usuario abra esa pantalla sería esperar a que se dé cuenta de
            // que no navega.
            await environment.settings.revalidateTLSTrust()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await environment.settings.revalidateTLSTrust() }
        }
        .onChange(of: environment.intro.outcome) { _, outcome in
            handle(outcome)
        }
    }

    /// Atiende el desenlace del intro.
    ///
    /// La petición de encender viaja hasta la Dashboard en vez de resolverse aquí porque es ella quien
    /// sabe traducir el estado del túnel en el gesto correcto —hoja de explicación o arranque directo—
    /// y esa regla ya está probada en `MonitoringPresentation`. Lo que sí es de aquí es **llevar al
    /// usuario a donde va a pasar algo**: el intro se puede haber pedido desde Ajustes, y dejar la
    /// petición en una pestaña que no se está mirando la haría invisible.
    private func handle(_ outcome: IntroOutcome?) {
        guard let outcome else { return }
        environment.intro.acknowledgeOutcome()
        guard outcome == .startMonitoring else { return }
        selection = .dashboard
        environment.dashboard.requestStart()
    }
}
