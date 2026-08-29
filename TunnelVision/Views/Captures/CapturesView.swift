import SwiftUI

/// La pantalla de capturas (`docs/ux/screens.md`): los ficheros `.pcap` que la extensión ha escrito,
/// lo que ocupan, y qué se puede hacer con ellos — compartirlos, borrarlos y cerrar el que está
/// abierto para poder exportarlo.
///
/// La vista no lee el directorio (es un actor) ni decide cuál de los ficheros está abierto: pinta lo
/// que le da `CapturesViewModel`, cuyas decisiones salen de funciones puras y probadas. Lo único que
/// resuelve aquí es la confirmación de borrado, porque el gesto es del usuario y la consecuencia no
/// se puede deshacer.
struct CapturesView: View {

    /// El estado del túnel decide si hay un fichero abriéndose ahora mismo y si rotar tiene sentido,
    /// así que la pantalla lo sigue igual que la Dashboard.
    let controller: TunnelController

    let viewModel: CapturesViewModel

    /// El fichero cuyo borrado está pendiente de confirmar. Es estado de la vista y no del view model
    /// porque no sobrevive a la pantalla: nada que confirmar queda pendiente al salir de ella.
    @State private var pendingDeletion: CaptureFileDisplay?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(CapturesPresentation.screenTitle)
                .screenCanvas()
                .toolbar { rotateButton }
                .refreshable { await viewModel.refresh() }
                .sheet(item: exportSheet) { summary in
                    FlowExportSheet(summary: summary) { viewModel.dismissExport() }
                }
                .confirmationDialog(
                    CapturesPresentation.deletionDialogTitle,
                    isPresented: deletionPrompt,
                    titleVisibility: .visible,
                    presenting: pendingDeletion
                ) { file in
                    Button(CapturesPresentation.deleteActionTitle, role: .destructive) {
                        Task { await viewModel.delete(sequence: file.sequence) }
                    }
                    Button(CommonCopy.cancel, role: .cancel) {}
                } message: { file in
                    Text(CapturesPresentation.deletionPrompt(for: file))
                }
        }
        .task {
            // Mismo orden que en la Dashboard: seguir el status, leer el real (que corrige el
            // inicial) y solo entonces mirar el directorio, para que un túnel ya encendido al abrir la
            // app marque su fichero abierto desde el primer pintado.
            controller.startObservingStatus()
            await controller.refresh()
            viewModel.tunnelStateDidChange(to: controller.state)
            await viewModel.refresh()
        }
        .onChange(of: controller.state) { _, newState in
            viewModel.tunnelStateDidChange(to: newState)
        }
    }

    // MARK: - Cuerpo

    @ViewBuilder
    private var content: some View {
        switch viewModel.content {
        case .loading:
            // Dentro de un `ScrollView` para que tirar para refrescar siga siendo la salida si la
            // primera lectura se queda colgada, igual que en la Timeline.
            ScrollView {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }

        case .placeholder(let placeholder):
            ScrollView {
                if let notice = viewModel.notice {
                    noticeBanner(notice)
                        .cardSurface(padding: Spacing.row, radius: CornerRadius.medium)
                        .padding(.horizontal, Spacing.card)
                }

                // La tarjeta la pone la pantalla, igual que en la Timeline y por lo mismo: la misma
                // vista es una fila de lista en el Flow Inspector.
                PlaceholderCard(placeholder: placeholder) { action in
                    Task { await viewModel.perform(action) }
                }
                .cardSurface(padding: Spacing.card)
                .padding(.horizontal, Spacing.card)
                .padding(.top, Spacing.generous)
            }

        case .list:
            List {
                if let notice = viewModel.notice {
                    Section {
                        noticeBanner(notice)
                            .listRowInsets(EdgeInsets(
                                top: Spacing.row,
                                leading: Spacing.card,
                                bottom: Spacing.row,
                                trailing: Spacing.card
                            ))
                            .listRowBackground(Color(.surface))
                    }
                }

                Section {
                    ForEach(viewModel.rows) { file in
                        CaptureFileRow(file: file, isDeleting: isDeleting(file))
                            .listRowBackground(Color(.surface))
                            .swipeActions(edge: .trailing) {
                                if file.isActionable {
                                    Button(
                                        CapturesPresentation.deleteActionTitle,
                                        systemImage: "trash",
                                        role: .destructive
                                    ) {
                                        pendingDeletion = file
                                    }
                                }
                            }
                    }
                } footer: {
                    Text(viewModel.summary.text)
                        .font(.metricLabel)
                        .foregroundStyle(Color(.neutral))
                }

                headroomSection
            }
            // Agrupada y no de tarjetas sueltas como la Timeline, **a propósito**: aquí las filas son
            // un inventario cerrado con un total debajo, y lo que hay que poder leer de un vistazo es
            // cuántos ficheros hay y cuánto ocupan. Lo que se le cambia al estilo del sistema es el
            // fondo —el lienzo detrás y `surface` en cada fila— para que sea nuestra paleta la que
            // separa la fila del fondo, y no dos grises de fábrica que no son de nadie.
            .listStyle(.insetGrouped)
            .listCanvas()
        }
    }

    /// Lo que contesta *¿esto me va a llenar el móvil?*: el inventario de arriba cruzado con los
    /// topes de Ajustes (`CaptureHeadroom`).
    ///
    /// Va **debajo del inventario y dentro de la misma lista**, no en una tarjeta aparte: es la
    /// lectura de lo que se acaba de leer, y sacarla del inventario la haría parecer otra cosa. Ocupa
    /// el sitio que la pantalla dejaba en blanco — 373 de los 874 puntos de un iPhone 17, medidos.
    ///
    /// La frase que explica el titular es el **pie** de la sección y no una fila: es lo mismo que hace
    /// el pie del inventario, y una explicación puesta como fila se leería como un dato más.
    @ViewBuilder
    private var headroomSection: some View {
        if let headroom = viewModel.headroom {
            let display = CapturesPresentation.headroom(headroom)

            Section {
                HeadroomSummaryRow(display: display)
                    .listRowBackground(Color(.surface))

                if let expiry = display.expiry {
                    HeadroomExpiryRow(expiry: expiry)
                        .listRowBackground(Color(.surface))
                }
            } header: {
                Text(CapturesPresentation.headroomSectionTitle)
            } footer: {
                Text(display.detail)
                    .font(.metricLabel)
                    .foregroundStyle(Color(.neutral))
            }
        }
    }

    /// El aviso de la última acción. Se descarta tocándolo: es información, no un diálogo, y dejarlo
    /// fijo en la pantalla lo convertiría en ruido a la tercera rotación.
    private func noticeBanner(_ notice: CapturesNotice) -> some View {
        Button {
            viewModel.dismissNotice()
        } label: {
            HStack(alignment: .top, spacing: Spacing.close) {
                Image(systemName: notice.role == .warning ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(notice.role.color)

                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(notice.message)
                        .font(.cardBody)
                        .multilineTextAlignment(.leading)

                    if let diagnostic = notice.diagnostic {
                        Text(diagnostic)
                            .font(.badge)
                            .foregroundStyle(Color(.neutral))
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint(CommonCopy.dismissNoticeHint)
    }

    /// Las dos acciones de la pantalla que no son de una fila. Rotar se queda visible con el túnel
    /// parado, pero apagado: esconderlo dejaría al usuario sin saber que existe la forma de cerrar un
    /// fichero sin parar la monitorización. Exportar no depende del túnel — lee el historial — y por
    /// eso está siempre disponible, también con la lista de capturas vacía.
    @ToolbarContentBuilder
    private var rotateButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await viewModel.rotate() }
                } label: {
                    Label(
                        CapturesPresentation.rotateActionTitle,
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(!viewModel.canRotate)

                Button {
                    Task { await viewModel.exportFlows() }
                } label: {
                    Label(
                        CapturesPresentation.exportActionTitle,
                        systemImage: "square.and.arrow.up.on.square"
                    )
                }
                .disabled(!viewModel.canExport)
            } label: {
                if viewModel.activity == .idle {
                    Label(CapturesPresentation.actionsMenuTitle, systemImage: "ellipsis.circle")
                } else {
                    ProgressView()
                }
            }
        }
    }

    // MARK: - Interno

    private var exportSheet: Binding<FlowExportSummary?> {
        Binding(
            get: { viewModel.pendingExport },
            set: { summary in
                if summary == nil { viewModel.dismissExport() }
            }
        )
    }

    private var deletionPrompt: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented { pendingDeletion = nil }
            }
        )
    }

    private func isDeleting(_ file: CaptureFileDisplay) -> Bool {
        viewModel.activity == .deleting(file.sequence)
    }
}
