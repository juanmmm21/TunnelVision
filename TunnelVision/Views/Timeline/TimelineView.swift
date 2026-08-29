import SwiftUI
import Shared

/// La Timeline (`docs/ux/screens.md`): el historial de conexiones, hacia atrás en el tiempo, con sus
/// filtros y sus tres vacíos.
///
/// La vista no consulta al `HistoryReader` —es un actor— ni decide qué enseñar cuando la lista está
/// vacía: pinta lo que le dice `TimelineViewModel.content`, que sale de una función pura y probada.
/// Lo único que decide aquí es cuándo pedir más (al aparecer el pie de la lista) y cuándo recargar
/// (al aparecer la pantalla y al tirar para refrescar), porque el historial no se actualiza solo:
/// quien escribe es la extensión y SQLite no notifica entre procesos.
struct TimelineView: View {

    @Bindable var viewModel: TimelineViewModel

    /// Solo la atraviesa: quien la usa es la pantalla de un paquete, dos niveles más abajo. Viaja por
    /// las vistas porque `CaptureLibrary` no tiene estado que poseer (ver `FlowInspectorView`).
    let library: CaptureLibrary

    /// Y el directorio de contenido descifrado, que baja hasta la conversación de una conexión por el
    /// mismo camino y por la misma razón.
    let plaintext: PlaintextLibrary

    /// El eje deja de ir **fijo** en los cuerpos de accesibilidad y baja a ser lo primero que se
    /// desplaza. A esos tamaños su pie ocupa cinco o seis líneas —y no se puede recortar, que es lo
    /// que el design system prohíbe—, así que fijo se comía la pantalla entera y la lista de
    /// conexiones quedaba debajo del todo, inalcanzable porque una banda fija no se desplaza. Como
    /// primera fila cabe entera y la lista vuelve a estar a un dedo.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var pinsScrub: Bool { !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                widthProbe
                // El lienzo se pinta en la **banda** y en la **lista**, cada una por su cuenta, y no
                // en el `VStack` que las contiene. No es un capricho de estilo: un fondo puesto en el
                // contenedor de una `List` —o cualquiera que suba hasta el área segura de arriba—
                // deja la barra de navegación **sin título grande**, y tampoco lo sustituye por uno
                // en línea: la pantalla se queda sin nombre. Comprobado en el Simulator con las tres
                // variantes; esta es la única que conserva "Timeline" en su sitio.
                if pinsScrub {
                    scrub
                        .background(Color(.canvas))
                }
                content
            }
            // Ni un rótulo de esta pantalla se escribe aquí: toda la copia sale del núcleo puro por
            // el catálogo de cadenas (`docs/development/02-coding-standards.md`, *Product copy*).
            .navigationTitle(TimelinePresentation.screenTitle)
            // Sin `placement`, y eso **no** es dejarlo a medias: con
            // `.navigationBarDrawer(displayMode: .always)` esta pantalla se quedaba **sin título
            // grande** —ni grande ni en línea que lo sustituyera—, así que arriba había ciento y pico
            // puntos de hueco vacío con solo el botón de filtros dentro. Comprobado en el Simulator
            // quitando solo esa línea: "Timeline" vuelve a su sitio.
            .searchable(
                text: $viewModel.searchText,
                prompt: TimelinePresentation.searchPrompt
            )
            .onSubmit(of: .search) {
                Task { await viewModel.submitSearch() }
            }
            .onChange(of: viewModel.searchText) { _, newValue in
                // Escribir no recarga (cada carga barre páginas del store), pero **borrar** sí:
                // al vaciar la barra el usuario está pidiendo la lista entera de vuelta, y
                // dejársela filtrada por lo que ya no se ve en pantalla sería mentirle.
                guard newValue.isEmpty else { return }
                Task { await viewModel.submitSearch() }
            }
            .toolbar { filterMenu }
            // La barra de navegación es **opaca**, y esto es lo que arregla que el título y el campo
            // de búsqueda atravesaran el eje al deslizar. Por encima del umbral de accesibilidad el
            // eje deja de ir fijo y pasa a ser la primera fila de la lista (ver `pinsScrub`), así que
            // se mete debajo de la barra — y una barra transparente no es algo detrás de lo que
            // esconderse: lo que se leía era el pie del eje **a través** del título. Volver a fijar el
            // eje no es la salida (a AX5 una banda fija se come la pantalla); darle a la barra algo
            // opaco, sí. El color es el lienzo, o sea el mismo que hay debajo, así que en lo alto de
            // la lista la costura no se ve.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.canvas), for: .navigationBar)
            .refreshable { await viewModel.refresh() }
        }
        .task {
            await viewModel.startObserving()
            await viewModel.refresh()
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }

    /// Lo que mide la pantalla, que es lo que decide **cuántos tramos** puede ofrecer el eje: cada uno
    /// se toca con el dedo (`ScrubCapacity`).
    ///
    /// Es una fila de **altura cero** y no un fondo de la lista ni de lo que la contiene, y no por
    /// gusto: en esta pantalla ya está pagado que lo que se cuelga alrededor de una `List` le cuesta
    /// el título grande a la barra de navegación (el lienzo, arriba). Un hermano de altura cero mide
    /// exactamente lo mismo —el ancho es el del `VStack`— sin tocar el layout de nadie.
    ///
    /// Y se mide aquí y no dentro de la barra de scrub porque esta vista existe desde el primer
    /// fotograma: la barra solo aparece cuando ya hay eje, así que medir allí obligaría a dibujar uno
    /// con la resolución equivocada y a volver a pedirlo entero.
    private var widthProbe: some View {
        GeometryReader { geometry in
            Color.clear
                .task(id: geometry.size.width) {
                    await viewModel.setScreenWidth(geometry.size.width)
                }
        }
        .frame(height: 0)
    }

    // MARK: - Barra de scrub

    /// El eje temporal, encima de la lista. Se dibuja también cuando la lista está vacía: si el vacío
    /// viene de un tramo sin conexiones, la barra es justo por donde se sale.
    ///
    /// Va dentro de una tarjeta y **sin la línea que lo separaba de la lista**: el eje es un control,
    /// no un encabezado, y una tarjeta lo dice sin gastar una regla — que además, con las filas ya
    /// convertidas en tarjetas, quedaría entre dos cosas que ya están separadas.
    @ViewBuilder
    private var scrub: some View {
        switch viewModel.scrub {
        case .hidden:
            EmptyView()

        case .axis(let axis):
            ScrubBar(
                axis: axis,
                selection: viewModel.highlightedInterval,
                viewing: viewModel.viewingInterval,
                offersFullReset: viewModel.zoom.offersFullReset,
                presentation: viewModel.scrubAxis,
                notice: viewModel.scrubNotice,
                onSelect: { bar in Task { await viewModel.selectInterval(bar) } },
                onSelectRange: { range in Task { await viewModel.selectRange(range) } },
                onClear: { Task { await viewModel.clearInterval() } },
                onZoomOut: { Task { await viewModel.zoomOut() } },
                onShowWholeHistory: { Task { await viewModel.showWholeHistory() } }
            )
            .cardSurface(padding: Spacing.row, radius: CornerRadius.medium)
            .padding(.horizontal, Spacing.card)
            .padding(.bottom, Spacing.close)

        case .unavailable(let message):
            Text(message)
                .font(.metricLabel)
                .foregroundStyle(Color(.neutral))
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(padding: Spacing.row, radius: CornerRadius.medium)
                .padding(.horizontal, Spacing.card)
                .padding(.bottom, Spacing.close)
        }
    }

    // MARK: - Cuerpo

    @ViewBuilder
    private var content: some View {
        switch viewModel.content {
        case .loading:
            // Dentro de un `ScrollView` para que tirar para refrescar siga funcionando: si la primera
            // carga se queda colgada, el gesto es la única salida que tiene el usuario.
            ScrollView {
                scrollingScrub
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
            // El lienzo va también aquí, y no solo en la lista: sin esto los dos cuerpos que no son
            // `List` —la carga y el hueco— se quedaban sobre el fondo de fábrica, que en claro es
            // blanco. Se veía como un salto de color al vaciarse un filtro.
            .screenCanvas()

        case .placeholder(let placeholder):
            ScrollView {
                scrollingScrub

                // La tarjeta la pone la pantalla y no `PlaceholderCard`: aquí el hueco cae sobre el
                // lienzo, pero en el Flow Inspector la misma vista es una **fila** de una lista
                // agrupada, y allí una superficie propia se montaría sobre la de la fila.
                PlaceholderCard(placeholder: placeholder) { action in
                    Task { await viewModel.perform(action) }
                }
                .cardSurface(padding: Spacing.card)
                .padding(.horizontal, Spacing.card)
                .padding(.top, Spacing.generous)
            }
            .screenCanvas()

        case .list:
            List {
                if !pinsScrub {
                    scrub
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                // La lista se pinta desde `rows` y no desde `flows`: cada fila llega con su copia ya
                // compuesta, hecha cuando el historial cambió y no cuando el dedo se mueve.
                ForEach(viewModel.rows) { row in
                    NavigationLink(value: row.flow) {
                        FlowRow(row: row)
                    }
                    .cardRow()
                }
                footer
            }
            .listStyle(.plain)
            .listCanvas()
            .navigationDestination(for: HistoryFlow.self) { flow in
                inspector(for: flow)
            }
        }
    }

    /// El eje cuando le toca desplazarse con el contenido, o nada si va fijo arriba. Lo usan los dos
    /// cuerpos que no son lista —la carga y el hueco—, donde el sitio lo pone un `ScrollView`.
    @ViewBuilder
    private var scrollingScrub: some View {
        if !pinsScrub {
            scrub
        }
    }

    /// La pantalla de una conexión. El view model lo construye el de la Timeline porque el historial
    /// abierto es suyo; el `else` no se alcanza desde una fila —una fila solo existe si hubo lector—,
    /// pero un destino vacío sería peor que decirlo.
    @ViewBuilder
    private func inspector(for flow: HistoryFlow) -> some View {
        if let viewModel = viewModel.makeInspector(for: flow) {
            FlowInspectorView(viewModel: viewModel, library: library, plaintext: plaintext)
        } else {
            let unavailable = TimelinePresentation.connectionUnavailable
            ContentUnavailableView(
                unavailable.title,
                systemImage: unavailable.systemImage,
                description: Text(unavailable.message)
            )
        }
    }

    /// El pie de la lista. `loadMore` es además el disparador de la paginación: la fila solo existe si
    /// queda historial, y pedir la página siguiente **al aparecer** es lo que hace que el scroll
    /// cargue solo sin que la vista tenga que vigilar posiciones.
    @ViewBuilder
    private var footer: some View {
        switch viewModel.footer {
        case .none:
            EmptyView()

        case .loadMore:
            ProgressView()
                .frame(maxWidth: .infinity)
                .modifier(TimelineFooterRow())
                .task { await viewModel.loadMore() }

        case .loadingOlder:
            ProgressView()
                .frame(maxWidth: .infinity)
                .modifier(TimelineFooterRow())

        case .endOfHistory:
            Text(TimelinePresentation.endOfHistoryMessage)
                .font(.metricLabel)
                .foregroundStyle(Color(.neutral))
                .frame(maxWidth: .infinity)
                .modifier(TimelineFooterRow())

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.metricLabel)
                .foregroundStyle(StatusRole.warning.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(TimelineFooterRow())
        }
    }

    // MARK: - Filtros

    @ToolbarContentBuilder
    private var filterMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(TimelinePresentation.timeSectionTitle, selection: timeRangeBinding) {
                    ForEach(TimelineTimeRange.allCases) { range in
                        // La selección es opcional porque un tramo elegido en la barra de scrub no es
                        // ninguna de estas opciones: entonces no hay ninguna marcada, que es lo
                        // honesto — dejar "Any time" marcado diría que la lista no está acotada.
                        Text(range.label).tag(Optional(range))
                    }
                }
                .pickerStyle(.inline)

                Section(TimelinePresentation.protocolSectionTitle) {
                    ForEach(TimelineProtocolFilter.allCases) { option in
                        Toggle(option.label, isOn: protocolBinding(option))
                    }
                }

                Section(TimelinePresentation.encryptionSectionTitle) {
                    ForEach(TLSStatusPresentation.allStatuses, id: \.self) { status in
                        Toggle(
                            TLSStatusPresentation.forStatus(status).label,
                            isOn: tlsBinding(status)
                        )
                    }
                }

                if viewModel.hasActiveFilters {
                    Section {
                        // El mismo rótulo que ofrece el vacío sin resultados, leído de la misma
                        // propiedad: dos literales iguales se separan en cuanto alguien traduce uno.
                        Button(
                            TimelinePresentation.clearFiltersActionTitle,
                            systemImage: "xmark.circle"
                        ) {
                            Task { await viewModel.clearFilters() }
                        }
                    }
                }
            } label: {
                Label(
                    TimelinePresentation.filterMenuTitle,
                    systemImage: viewModel.hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            }
        }
    }

    /// Los bindings del menú escriben a través del view model (que recarga) en vez de mutar estado de
    /// la vista: el filtro vive donde vive la lista, no en la barra que lo enseña.
    private var timeRangeBinding: Binding<TimelineTimeRange?> {
        Binding(
            get: { viewModel.timeRange },
            set: { range in
                // El menú no ofrece ninguna opción que deseleccione, así que el `nil` no llega desde
                // aquí: se ignora en vez de inventarle un significado.
                guard let range else { return }
                Task { await viewModel.setTimeRange(range) }
            }
        )
    }

    private func protocolBinding(_ option: TimelineProtocolFilter) -> Binding<Bool> {
        Binding(
            get: { viewModel.protocolSelection.contains(option) },
            set: { _ in Task { await viewModel.toggleProtocol(option) } }
        )
    }

    private func tlsBinding(_ status: TLSInspectionStatus) -> Binding<Bool> {
        Binding(
            get: { viewModel.tlsSelection.contains(status) },
            set: { _ in Task { await viewModel.toggleTLSStatus(status) } }
        )
    }
}

/// El pie de la lista: no es una conexión, así que **no es una tarjeta**. Se queda sobre el lienzo
/// desnudo, que es lo que hace que se lea como el final de la lista y no como una fila más.
private struct TimelineFooterRow: ViewModifier {

    func body(content: Content) -> some View {
        content
            .padding(.vertical, Spacing.row)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 0, leading: Spacing.card, bottom: 0, trailing: Spacing.card
            ))
    }
}
