import SwiftUI

/// La Dashboard (`docs/ux/screens.md`): control de monitorización, throughput en vivo, contadores y
/// los hosts que más mueven ahora mismo.
///
/// Es la pantalla que une los dos servicios: el estado lo manda `TunnelController` y los datos vienen
/// del `DashboardViewModel`. La vista no habla nunca con el `LiveFeedReader` —es un actor— ni decide
/// cuándo arrancarlo: se limita a contarle al view model que el túnel cambió de estado.
struct DashboardView: View {

    let controller: TunnelController
    let viewModel: DashboardViewModel

    @State private var isShowingPriming = false

    /// En los cuerpos de accesibilidad las tres tarjetas de contadores no caben en una fila: apiladas,
    /// cada una conserva el ancho entero y el número no tiene que encogerse para caber.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Volver a primer plano es un evento del feed y no de la pantalla: el ring puede haber muerto
    /// mientras la app no estaba (`DashboardViewModel.sceneDidBecomeActive`).
    @Environment(\.scenePhase) private var scenePhase

    private var presentation: MonitoringPresentation {
        MonitoringPresentation.forState(controller.state)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.card) {
                    MonitoringToggle(presentation: presentation, onAction: perform)

                    if viewModel.isDroppingRecords {
                        DropIndicator(droppedRecords: viewModel.snapshot.droppedRecords)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ThroughputChart(
                        samples: viewModel.snapshot.throughput,
                        rateIn: viewModel.currentRateIn,
                        rateOut: viewModel.currentRateOut
                    )
                    .cardSurface()

                    counters

                    talkers
                }
                .padding(Spacing.card)
            }
            .navigationTitle(DashboardPresentation.screenTitle)
            .screenCanvas()
        }
        .task {
            // El orden importa: primero se sigue el status, luego se lee el real (que corrige el
            // inicial), y solo entonces se ajusta el feed — si no, un túnel que ya estaba encendido al
            // abrir la app se quedaría sin feed hasta el siguiente cambio de estado.
            controller.startObservingStatus()
            await controller.refresh()
            await viewModel.tunnelStateDidChange(to: controller.state)
            viewModel.startObserving()
        }
        .onDisappear {
            viewModel.stopObserving()
        }
        .onChange(of: controller.state) { _, newState in
            Task { await viewModel.tunnelStateDidChange(to: newState) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.sceneDidBecomeActive() }
        }
        .onChange(of: viewModel.hasPendingStartRequest) { _, isPending in
            guard isPending else { return }
            honourStartRequest()
        }
        .sheet(isPresented: $isShowingPriming) {
            ConsentSheet.vpnPermission {
                Task { await controller.startMonitoring() }
            }
        }
    }

    // MARK: - Secciones

    /// Los tres contadores, bajo su rótulo. El rótulo no es adorno: sin él, *Received* y *Sent* salen
    /// dos veces seguidas en la misma pantalla —tasa arriba, total aquí— sin nada que diga cuál es
    /// cuál.
    private var counters: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            SectionHeader(DashboardPresentation.countersTitle)
            counterTiles
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var counterTiles: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Spacing.row))
            : AnyLayout(HStackLayout(spacing: Spacing.row))
        return layout {
            StatTile(
                title: TrafficDirectionStyle.inboundLabel,
                value: DisplayFormat.bytes(viewModel.snapshot.bytesIn),
                systemImage: TrafficDirectionStyle.inboundSymbol,
                tint: TrafficDirectionStyle.inboundColor
            )
            StatTile(
                title: TrafficDirectionStyle.outboundLabel,
                value: DisplayFormat.bytes(viewModel.snapshot.bytesOut),
                systemImage: TrafficDirectionStyle.outboundSymbol,
                tint: TrafficDirectionStyle.outboundColor
            )
            StatTile(
                title: DashboardPresentation.packetsCounterLabel,
                value: DisplayFormat.count(viewModel.snapshot.packetCount),
                systemImage: "square.stack.3d.up",
                tint: .primary
            )
        }
    }

    @ViewBuilder
    private var talkers: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            SectionHeader(DashboardPresentation.talkersTitle)

            if viewModel.topTalkers.isEmpty {
                emptyTalkers
            } else {
                // Las filas llevan su propio relleno y los separadores **no**: una línea que llega al
                // filo de la tarjeta es lo que se lee como una lista, y una recortada, como cinco
                // tarjetas pegadas.
                VStack(spacing: 0) {
                    ForEach(viewModel.topTalkers) { talker in
                        TopTalkerRow(talker: talker)
                            .padding(.horizontal, Spacing.card)
                            .padding(.vertical, Spacing.row)
                        if talker.id != viewModel.topTalkers.last?.id {
                            Divider()
                        }
                    }
                }
                .cardSurface(padding: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cuál de los dos vacíos toca lo decide el núcleo puro (`DashboardPresentation`), no esta vista:
    /// la regla —sin ring la app **espera**, con ring y sin paquetes de verdad no ha pasado tráfico—
    /// es lo que separa el vacío honesto del que miente, y ahí se puede afirmar.
    private var emptyTalkers: some View {
        EmptyStateView(DashboardPresentation.talkersEmptyState(isAttached: viewModel.isAttached))
    }

    // MARK: - Acciones

    private func perform(_ action: MonitoringAction) {
        switch action {
        case .startAfterPriming:
            // El único camino que trae el diálogo del sistema: se explica antes, siempre.
            isShowingPriming = true
        case .start, .retry:
            Task { await controller.startMonitoring() }
        case .stop:
            Task { await controller.stopMonitoring() }
        }
    }

    /// Atiende la petición de encender que llega del intro (M10).
    ///
    /// Se marca atendida **antes** de actuar: si actuar abre la hoja de explicación y el usuario la
    /// cierra con *Not now*, la petición no puede seguir pendiente esperando a que se vuelva a pasar
    /// por esta pestaña. Qué hacer con ella lo decide `startRequestAction`, que es donde está probado
    /// que una petición de encender nunca se atiende apagando.
    private func honourStartRequest() {
        viewModel.startRequestHandled()
        guard let action = presentation.startRequestAction else { return }
        perform(action)
    }
}
