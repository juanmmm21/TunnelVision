import SwiftUI

/// A dónde se navega dentro de la pestaña de auditoría.
///
/// Lleva identificadores y no los valores: lo que se enseña al llegar se relee del view model, así
/// que una pantalla abierta sobre un proyecto que se acaba de editar enseña el editado.
enum AuditRoute: Hashable {
    case project(Int64)
    case session(Int64)
}

/// La pestaña de auditoría (`docs/ux/audit.md`): los proyectos, cuál está grabando, y la entrada a
/// crear uno.
///
/// La pila de navegación es de `RootView` y no de aquí porque **hay que poder llegar desde fuera**:
/// la franja de la Dashboard lleva a la sesión abierta, y eso es escribir esta pila desde otra
/// pestaña.
struct AuditView: View {

    let viewModel: AuditViewModel

    @Binding var path: [AuditRoute]

    @State private var isCreatingProject = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(AuditPresentation.screenTitle)
                .screenCanvas()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isCreatingProject = true
                        } label: {
                            Label(AuditPresentation.newProjectActionTitle, systemImage: "plus")
                        }
                    }
                }
                .refreshable { await viewModel.refresh() }
                .navigationDestination(for: AuditRoute.self) { route in
                    switch route {
                    case .project(let id):
                        AuditProjectView(viewModel: viewModel, projectID: id)
                    case .session(let id):
                        AuditSessionView(viewModel: viewModel, sessionID: id)
                    }
                }
                .sheet(isPresented: $isCreatingProject) {
                    AuditProjectEditorSheet(viewModel: viewModel, editing: nil)
                }
        }
        .task { await viewModel.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.content {
        case .loading:
            // Dentro de un `ScrollView` para que tirar para refrescar siga siendo la salida si la
            // primera lectura se queda colgada, igual que en Captures.
            ScrollView {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }

        case .placeholder(let placeholder):
            ScrollView {
                if let notice = viewModel.notice {
                    AuditNoticeBanner(notice: notice) { viewModel.dismissNotice() }
                        .cardSurface(padding: Spacing.row, radius: CornerRadius.medium)
                        .padding(.horizontal, Spacing.card)
                }

                PlaceholderCard(placeholder: placeholder) { action in
                    switch action {
                    case .newProject:
                        isCreatingProject = true
                    case .retry:
                        Task { await viewModel.perform(action) }
                    }
                }
                .cardSurface(padding: Spacing.card)
                .padding(.horizontal, Spacing.card)
                .padding(.top, Spacing.generous)
            }

        case .list:
            List {
                if let notice = viewModel.notice {
                    Section {
                        AuditNoticeBanner(notice: notice) { viewModel.dismissNotice() }
                    }
                    .listRowBackground(Color(.surface))
                }

                Section {
                    ForEach(viewModel.projectRows) { row in
                        NavigationLink(value: AuditRoute.project(row.id)) {
                            AuditProjectRowView(row: row)
                        }
                    }
                } header: {
                    SectionHeader(AuditPresentation.projectsSectionTitle)
                } footer: {
                    AuditSectionFooter(AuditPresentation.projectsFooter)
                }
                .listRowBackground(Color(.surface))
            }
            // Agrupada, como Captures: es un inventario corto, no un historial que se recorre.
            .listStyle(.insetGrouped)
            .listCanvas()
        }
    }
}

/// Una fila de la lista de proyectos: el nombre, cuántas sesiones tiene y, solo si una está
/// grabando, el distintivo.
///
/// Sin carril ni icono, por la regla de `CaptureFileRow`: un símbolo en cada fila diría *esto es un
/// proyecto* en una lista de proyectos. La excepción —el que graba— se escribe; el supuesto calla.
struct AuditProjectRowView: View {

    let row: AuditProjectRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(row.name)
                .font(.cardTitle)

            // Apilados y no en línea: el distintivo y la cuenta crecen los dos con la letra, y en
            // línea el segundo acabaría envuelto en una columna de dos palabras.
            if row.isRecording {
                AuditRecordingBadge()
            }

            Text(row.detail)
                .font(.metricLabel)
                .foregroundStyle(Color(.neutral))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.accessibilityValue)
    }
}
