import Shared
import SwiftUI

/// El formulario con el que se abre una sesión: qué papel juega, qué release observa y qué se quiere
/// anotar. Lo demás —dispositivo, sistema, versión de la herramienta, estado de la inspección— **no
/// se pregunta**: se lee del dispositivo al confirmar (`AuditRecordingConditions`).
///
/// Enseña **antes de grabar** qué se va a poder leer de la sesión sobre pinning. Es el único momento
/// en que sirve: una sesión grabada sin la inspección encendida no se arregla después, y enterarse
/// en el informe es enterarse tarde.
struct AuditSessionStartSheet: View {

    let viewModel: AuditViewModel
    let projectID: Int64

    @State private var form: AuditSessionForm
    @State private var issue: AuditFormIssue?
    @State private var isStarting = false

    @Environment(\.dismiss) private var dismiss

    init(viewModel: AuditViewModel, projectID: Int64, suggestedRole: AuditSessionRole) {
        self.viewModel = viewModel
        self.projectID = projectID
        _form = State(initialValue: AuditSessionForm(role: suggestedRole))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(AuditPresentation.sessionRolePickerTitle, selection: $form.role) {
                        ForEach(AuditSessionRole.allCases, id: \.self) { role in
                            Text(AuditPresentation.label(for: role)).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    AuditSectionFooter(AuditPresentation.sessionRoleFooter(form.role))
                }
                .listRowBackground(Color(.surface))

                // Una baseline no lleva release: se graba sin la app auditada, así que los campos
                // no se apagan, desaparecen — apagados preguntarían por algo que no existe.
                if form.role == .audit {
                    Section {
                        TextField(AuditPresentation.versionFieldPrompt, text: $form.version)
                            .accessibilityLabel(AuditPresentation.versionFieldTitle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)

                        TextField(AuditPresentation.buildFieldPrompt, text: $form.build)
                            .accessibilityLabel(AuditPresentation.buildFieldTitle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)

                        if let issue, issue == .missingRelease {
                            AuditFormIssueText(issue: issue)
                        }
                    } header: {
                        SectionHeader(AuditPresentation.releaseSectionTitle)
                    } footer: {
                        AuditSectionFooter(AuditPresentation.releaseFooter)
                    }
                    .listRowBackground(Color(.surface))
                }

                if let conditions = viewModel.currentInspection {
                    let pinning = AuditPresentation.pinningForecast(PinningEvidence.reading(conditions))
                    Section {
                        Label {
                            Text(pinning.headline)
                                .font(.cardTitle)
                        } icon: {
                            Image(systemName: pinning.systemImage)
                                .foregroundStyle(pinning.role.color)
                        }
                    } header: {
                        SectionHeader(AuditPresentation.conditionsSectionTitle)
                    } footer: {
                        AuditSectionFooter(pinning.detail)
                    }
                    .listRowBackground(Color(.surface))
                }

                Section {
                    TextField(AuditPresentation.notesFieldPrompt, text: $form.notes, axis: .vertical)
                        .accessibilityLabel(AuditPresentation.notesSectionTitle)
                        .lineLimit(3...6)
                } header: {
                    SectionHeader(AuditPresentation.notesSectionTitle)
                }
                .listRowBackground(Color(.surface))

                Section {
                    Button {
                        start()
                    } label: {
                        Text(AuditPresentation.startRecordingActionTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .brandProminentButton()
                    .controlSize(.large)
                    .disabled(isStarting)
                    // El botón es la fila: sin fondo ni márgenes de celda, que lo dejarían como un
                    // botón relleno dentro de una tarjeta blanca.
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .listCanvas()
            .navigationTitle(AuditPresentation.startSessionFormTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.canvas), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CommonCopy.cancel) { dismiss() }
                }
            }
            .onChange(of: form) { _, _ in issue = nil }
        }
        .task { await viewModel.prepareSessionForm() }
    }

    private func start() {
        isStarting = true
        Task {
            let found = await viewModel.startSession(form, projectID: projectID)
            isStarting = false
            if let found {
                issue = found
            } else {
                dismiss()
            }
        }
    }
}
