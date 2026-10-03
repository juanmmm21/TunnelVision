import Shared
import SwiftUI

/// El formulario de un proyecto de auditoría: su nombre, el bundle identifier de la app y la
/// allowlist. Sirve para crear y para editar; lo que cambia es de dónde sale el formulario y a
/// quién se le guarda.
///
/// El formulario es estado de la **hoja** y no del view model: es lo que alguien está tecleando, y
/// si la hoja se cierra sin guardar no queda nada pendiente en ningún sitio. Lo que tenga mal lo
/// decide la capa pura (`AuditProjectForm.draft`) y aquí solo se señala.
struct AuditProjectEditorSheet: View {

    let viewModel: AuditViewModel

    /// El proyecto que se edita, o `nil` si se está creando uno.
    let editing: AuditProject?

    @State private var form: AuditProjectForm
    @State private var issue: AuditFormIssue?
    @State private var isSaving = false

    @Environment(\.dismiss) private var dismiss

    init(viewModel: AuditViewModel, editing: AuditProject?) {
        self.viewModel = viewModel
        self.editing = editing
        _form = State(initialValue: editing.map(AuditProjectForm.init(editing:)) ?? AuditProjectForm())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AuditPresentation.projectNameFieldPrompt, text: $form.name)
                        .accessibilityLabel(AuditPresentation.projectNameFieldTitle)

                    TextField(AuditPresentation.projectBundleFieldPrompt, text: $form.bundleIdentifier)
                        .font(.literal)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .accessibilityLabel(AuditPresentation.bundleIdentifierLabel)

                    if issue == .emptyProjectName {
                        AuditFormIssueText(issue: .emptyProjectName)
                    }
                } header: {
                    SectionHeader(AuditPresentation.detailsSectionTitle)
                } footer: {
                    AuditSectionFooter(AuditPresentation.bundleIdentifierFooter)
                }
                .listRowBackground(Color(.surface))

                Section {
                    ForEach($form.lines) { $line in
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            TextField(AuditPresentation.allowlistPatternFieldPrompt, text: $line.pattern)
                                .font(.literal)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .accessibilityLabel(AuditPresentation.allowlistPatternFieldTitle)

                            TextField(AuditPresentation.allowlistNoteFieldPrompt, text: $line.note)
                                .font(.supporting)
                                .accessibilityLabel(AuditPresentation.allowlistNoteFieldTitle)

                            // El problema va **en la línea que lo tiene**: una allowlist de veinte
                            // entradas con un aviso suelto arriba obliga a buscar cuál es.
                            if let issue, issue.line == line.id {
                                AuditFormIssueText(issue: issue)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(
                                AuditPresentation.removeAllowlistLineActionTitle,
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                form.lines.removeAll { $0.id == line.id }
                            }
                        }
                    }

                    Button {
                        form.lines.append(AllowlistLine())
                    } label: {
                        Label(AuditPresentation.addAllowlistLineActionTitle, systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    SectionHeader(AuditPresentation.allowlistSectionTitle)
                } footer: {
                    AuditSectionFooter(AuditPresentation.allowlistFooter)
                }
                .listRowBackground(Color(.surface))
            }
            .listCanvas()
            .navigationTitle(
                editing == nil
                    ? AuditPresentation.newProjectFormTitle
                    : AuditPresentation.editProjectFormTitle
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.canvas), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CommonCopy.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AuditPresentation.saveActionTitle) { save() }
                        .disabled(isSaving)
                }
            }
            // Lo señalado deja de estarlo en cuanto se toca el formulario: un aviso que sigue ahí
            // después de corregir lo que decía se lee como que la corrección no ha servido.
            .onChange(of: form) { _, _ in issue = nil }
        }
    }

    private func save() {
        isSaving = true
        Task {
            let found = await viewModel.save(form, editing: editing?.id)
            isSaving = false
            if let found {
                issue = found
            } else {
                // Si el fallo no era del formulario, el aviso está en la pantalla de detrás, y
                // dejar la hoja encima lo taparía.
                dismiss()
            }
        }
    }
}
