import Shared
import SwiftUI

/// La pantalla de un proyecto de auditoría (`docs/ux/audit.md`): sus sesiones, la entrada a abrir
/// una, y la allowlist contra la que se juzgan.
///
/// No guarda el proyecto: lo relee del view model por identificador en cada evaluación, así que lo
/// que se edita en la hoja o se cierra en la pantalla de una sesión aparece aquí sin que nadie tenga
/// que avisar. Si el proyecto deja de existir —se ha borrado desde aquí mismo—, la pantalla se cierra.
struct AuditProjectView: View {

    let viewModel: AuditViewModel
    let projectID: Int64

    @State private var isEditing = false
    @State private var isStartingSession = false

    /// El proyecto cuyo borrado está pendiente de confirmar. Viaja por el closure `presenting` del
    /// diálogo: SwiftUI descarta un `confirmationDialog` **antes** de ejecutar la acción de su
    /// botón, así que una acción que releyera este estado lo encontraría a `nil`.
    @State private var pendingDeletion: AuditProjectDisplay?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let display = viewModel.projectDisplay(id: projectID) {
                list(display)
            } else {
                // El proyecto ya no existe. Se queda un instante mientras la pila se cierra.
                Color(.canvas).ignoresSafeArea()
            }
        }
        .onChange(of: viewModel.projectDisplay(id: projectID) == nil) { _, isGone in
            if isGone { dismiss() }
        }
    }

    private func list(_ display: AuditProjectDisplay) -> some View {
        List {
            if let notice = viewModel.notice {
                Section {
                    AuditNoticeBanner(notice: notice) { viewModel.dismissNotice() }
                }
                .listRowBackground(Color(.surface))
            }

            sessionsSection(display)
            allowlistSection(display)
            detailsSection(display)
        }
        .listStyle(.insetGrouped)
        .listCanvas()
        // Las filas se deslizan bajo la barra, y la de iOS 26 es cristal: sin fondo opaco se leen a
        // través del título (`docs/ux/design-system.md`).
        // En línea, como todas las pantallas a las que se llega empujando: con el título grande y
        // la barra opaca, la pantalla se quedaba **sin título** (visto en el Simulator).
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.canvas), for: .navigationBar)
        .navigationTitle(display.name)
        .refreshable { await viewModel.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isEditing = true
                    } label: {
                        Label(AuditPresentation.editProjectActionTitle, systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDeletion = display
                    } label: {
                        Label(AuditPresentation.deleteProjectActionTitle, systemImage: "trash")
                    }
                } label: {
                    Label(AuditPresentation.projectMenuTitle, systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            AuditProjectEditorSheet(viewModel: viewModel, editing: viewModel.project(id: projectID)?.project)
        }
        .sheet(isPresented: $isStartingSession) {
            AuditSessionStartSheet(
                viewModel: viewModel,
                projectID: projectID,
                suggestedRole: AuditSessionForm.suggestedRole(
                    existing: viewModel.project(id: projectID)?.sessions ?? []
                )
            )
        }
        .confirmationDialog(
            pendingDeletion.map { AuditPresentation.deleteProjectDialogTitle(name: $0.name) } ?? "",
            isPresented: deletionPrompt,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { project in
            Button(AuditPresentation.deleteProjectActionTitle, role: .destructive) {
                Task { await viewModel.deleteProject(id: project.id) }
            }
            Button(CommonCopy.cancel, role: .cancel) {}
        } message: { project in
            Text(AuditPresentation.deleteProjectPrompt(sessionCount: project.sessions.count))
        }
    }

    // MARK: - Secciones

    private func sessionsSection(_ display: AuditProjectDisplay) -> some View {
        Section {
            ForEach(display.sessions) { session in
                NavigationLink(value: AuditRoute.session(session.id)) {
                    AuditSessionRowView(row: session)
                }
            }

            // Sin alto mínimo propio: una fila de lista ya mide más que el mínimo táctil, y sumarle
            // el del rótulo la dejaba en 74 pt (medido con `idb ui describe-all`).
            Button {
                isStartingSession = true
            } label: {
                Label(AuditPresentation.startSessionActionTitle, systemImage: "record.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Apagado, el sistema atenúa la palabra pero deja el símbolo con el tinte de la
                    // marca, y un símbolo encendido junto a una palabra apagada se lee como activo.
                    .foregroundStyle(display.canStartSession ? StatusRole.accent.color : Color(.neutral))
            }
            .disabled(!display.canStartSession || viewModel.isWorking)
        } header: {
            SectionHeader(AuditPresentation.sessionsSectionTitle)
        } footer: {
            // Una sola frase a la vez: por qué el botón está apagado manda sobre el consejo de
            // empezar por la baseline, que con una sesión ya abierta no viene a cuento.
            if let blocked = display.startBlockedNote {
                AuditSectionFooter(blocked)
            } else if display.sessions.isEmpty {
                AuditSectionFooter(AuditPresentation.sessionsEmptyNote)
            }
        }
        .listRowBackground(Color(.surface))
    }

    private func allowlistSection(_ display: AuditProjectDisplay) -> some View {
        Section {
            if display.allowlist.isEmpty {
                Text(AuditPresentation.allowlistEmptyNote)
                    .font(.cardBody)
                    .foregroundStyle(Color(.neutral))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(display.allowlist) { entry in
                    AuditAllowlistRowView(entry: entry)
                }
            }
        } header: {
            SectionHeader(AuditPresentation.allowlistSectionTitle)
        } footer: {
            AuditSectionFooter(AuditPresentation.allowlistFooter)
        }
        .listRowBackground(Color(.surface))
    }

    @ViewBuilder
    private func detailsSection(_ display: AuditProjectDisplay) -> some View {
        // Solo cuando hay: el identificador es opcional, y una sección entera para decir que no se
        // escribió sería hablar de un campo, no del proyecto.
        if let bundleIdentifier = display.bundleIdentifier {
            Section {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(AuditPresentation.bundleIdentifierLabel)
                        .font(.cardBody)
                    // Apilado y en el papel `literal`: es un dato que se lee carácter a carácter, y
                    // en dos columnas un identificador largo envolvería a mitad de palabra.
                    Text(bundleIdentifier)
                        .font(.literal)
                        .foregroundStyle(Color(.neutral))
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            } header: {
                SectionHeader(AuditPresentation.detailsSectionTitle)
            } footer: {
                AuditSectionFooter(AuditPresentation.bundleIdentifierFooter)
            }
            .listRowBackground(Color(.surface))
        }
    }

    private var deletionPrompt: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented { pendingDeletion = nil }
            }
        )
    }
}

/// Una fila de la lista de sesiones: qué release observó y cuándo empezó, con el distintivo si es la
/// que está grabando.
struct AuditSessionRowView: View {

    let row: AuditSessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(row.title)
                .font(.cardTitle)

            if row.isRecording {
                AuditRecordingBadge()
            }

            Text(row.startedAt, format: Date.FormatStyle.dayAndTime)
                .font(.metricLabel)
                .foregroundStyle(Color(.neutral))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Una entrada de la allowlist: el patrón como dato literal y, debajo, para qué es.
struct AuditAllowlistRowView: View {

    let entry: AuditAllowlistRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(entry.pattern)
                .font(.literal)
                .textSelection(.enabled)

            if let note = entry.note {
                Text(note)
                    .font(.metricLabel)
                    .foregroundStyle(Color(.neutral))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
