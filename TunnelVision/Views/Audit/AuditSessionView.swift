import Shared
import SwiftUI

/// La pantalla de una sesión de auditoría (`docs/ux/audit.md`): si está grabando, qué lleva, qué se
/// podrá leer de ella sobre pinning, sus marcadores, y las dos salidas — cerrarla y borrarla.
struct AuditSessionView: View {

    let viewModel: AuditViewModel
    let sessionID: Int64

    @State private var isConfirmingEnd = false
    @State private var isConfirmingDeletion = false
    @State private var isNamingMarker = false
    @State private var customMarkerLabel = ""

    @Environment(\.dismiss) private var dismiss

    private var display: AuditSessionDisplay? {
        guard let display = viewModel.sessionDisplay, display.id == sessionID else { return nil }
        return display
    }

    var body: some View {
        Group {
            if let display {
                list(display)
            } else {
                ScrollView {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
                .screenCanvas()
            }
        }
        .task { await viewModel.loadSession(id: sessionID) }
    }

    private func list(_ display: AuditSessionDisplay) -> some View {
        List {
            if let notice = viewModel.notice {
                Section {
                    AuditNoticeBanner(notice: notice) { viewModel.dismissNotice() }
                }
                .listRowBackground(Color(.surface))
            }

            statusSection(display)
            if display.isRecording {
                addMarkerSection(display)
            }
            markersSection(display)
            pinningSection(display)
            environmentSection(display)
            if let notes = display.notes {
                notesSection(notes)
            }
            actionsSection(display)
        }
        .listStyle(.insetGrouped)
        .listCanvas()
        // En línea, como todas las pantallas a las que se llega empujando: con el título grande y
        // la barra opaca, la pantalla se quedaba **sin título** (visto en el Simulator).
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.canvas), for: .navigationBar)
        .navigationTitle(display.title)
        .refreshable {
            await viewModel.refresh()
            await viewModel.loadSession(id: sessionID)
        }
        // Las dos confirmaciones llevan la sesión en su acción por parámetro y no la releen: SwiftUI
        // descarta el diálogo antes de ejecutar el botón.
        .confirmationDialog(
            AuditPresentation.endSessionDialogTitle,
            isPresented: $isConfirmingEnd,
            titleVisibility: .visible,
            presenting: display.id
        ) { id in
            Button(AuditPresentation.endSessionActionTitle) {
                Task { await viewModel.endSession(id: id) }
            }
            Button(CommonCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(AuditPresentation.endSessionPrompt)
        }
        .confirmationDialog(
            AuditPresentation.deleteSessionDialogTitle,
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: display.id
        ) { id in
            Button(AuditPresentation.deleteSessionActionTitle, role: .destructive) {
                Task {
                    await viewModel.deleteSession(id: id)
                    dismiss()
                }
            }
            Button(CommonCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(AuditPresentation.deleteSessionPrompt)
        }
        .alert(AuditPresentation.customMarkerDialogTitle, isPresented: $isNamingMarker) {
            TextField(AuditPresentation.customMarkerFieldPrompt, text: $customMarkerLabel)
            Button(AuditPresentation.customMarkerConfirmTitle) {
                let label = customMarkerLabel
                customMarkerLabel = ""
                Task { await viewModel.addMarker(.custom(label), toSession: display.id) }
            }
            .disabled(customMarkerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(CommonCopy.cancel, role: .cancel) { customMarkerLabel = "" }
        }
    }

    // MARK: - Secciones

    /// El estado, que es por lo que se abre esta pantalla: si sigue grabando, y cuánto lleva.
    private func statusSection(_ display: AuditSessionDisplay) -> some View {
        Section {
            Label {
                Text(display.status)
                    .font(.cardTitle)
            } icon: {
                Image(systemName: display.isRecording ? "record.circle" : "checkmark.circle")
                    .foregroundStyle(display.isRecording ? StatusRole.accent.color : Color(.neutral))
            }

            ValueRow(label: AuditPresentation.connectionsLabel, value: display.connections)

            ForEach(display.facts) { fact in
                AuditFactRow(fact: fact)
            }
        } footer: {
            AuditSectionFooter(display.statusDetail)
        }
        .listRowBackground(Color(.surface))
    }

    /// Los marcadores de un toque. Van **encima** de la lista de los ya puestos: mientras se graba,
    /// esto es lo que se viene a hacer aquí, con la app auditada esperando en segundo plano.
    private func addMarkerSection(_ display: AuditSessionDisplay) -> some View {
        Section {
            ForEach(AuditPresentation.markerChoices) { choice in
                Button {
                    Task { await viewModel.addMarker(choice.kind, toSession: display.id) }
                } label: {
                    Label(choice.title, systemImage: choice.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
                isNamingMarker = true
            } label: {
                Label(AuditPresentation.customMarkerActionTitle, systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            SectionHeader(AuditPresentation.addMarkerSectionTitle)
        }
        .disabled(viewModel.isWorking)
        .listRowBackground(Color(.surface))
    }

    private func markersSection(_ display: AuditSessionDisplay) -> some View {
        Section {
            if display.markers.isEmpty {
                Text(AuditPresentation.markersEmptyNote)
                    .font(.cardBody)
                    .foregroundStyle(Color(.neutral))
            } else {
                ForEach(display.markers) { marker in
                    AuditFactRow(fact: AuditFact(label: marker.title, value: .instant(marker.date)))
                }
            }
        } header: {
            SectionHeader(AuditPresentation.markersSectionTitle)
        } footer: {
            AuditSectionFooter(AuditPresentation.markersFooter(isRecording: display.isRecording))
        }
        .listRowBackground(Color(.surface))
    }

    /// Qué se podrá leer de esta sesión sobre pinning. El titular va con símbolo **y** color; la
    /// explicación, bajo la sección como el resto de la prosa fija.
    private func pinningSection(_ display: AuditSessionDisplay) -> some View {
        Section {
            Label {
                Text(display.pinning.headline)
                    .font(.cardTitle)
            } icon: {
                Image(systemName: display.pinning.systemImage)
                    .foregroundStyle(display.pinning.role.color)
            }
        } header: {
            SectionHeader(AuditPresentation.pinningSectionTitle)
        } footer: {
            AuditSectionFooter(display.pinning.detail)
        }
        .listRowBackground(Color(.surface))
    }

    private func environmentSection(_ display: AuditSessionDisplay) -> some View {
        Section {
            ForEach(display.environment) { fact in
                AuditFactRow(fact: fact)
            }
        } header: {
            SectionHeader(AuditPresentation.environmentSectionTitle)
        } footer: {
            AuditSectionFooter(AuditPresentation.environmentFooter)
        }
        .listRowBackground(Color(.surface))
    }

    private func notesSection(_ notes: String) -> some View {
        Section {
            // Con las palabras de quien las escribió y seleccionables: no es copia nuestra.
            Text(notes)
                .font(.cardBody)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            SectionHeader(AuditPresentation.notesSectionTitle)
        }
        .listRowBackground(Color(.surface))
    }

    private func actionsSection(_ display: AuditSessionDisplay) -> some View {
        Section {
            if display.isRecording {
                Button {
                    isConfirmingEnd = true
                } label: {
                    Label(AuditPresentation.endSessionActionTitle, systemImage: "stop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button(role: .destructive) {
                isConfirmingDeletion = true
            } label: {
                Label(AuditPresentation.deleteSessionActionTitle, systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(viewModel.isWorking)
        .listRowBackground(Color(.surface))
    }
}

/// Un hecho de una sesión: su etiqueta y su valor. `LabeledContent` por debajo, como `ValueRow`,
/// porque es quien apila etiqueta y valor a los tamaños de accesibilidad.
///
/// Existe aparte de `ValueRow` porque un instante lo escribe **el dispositivo** —huso y reloj de 12
/// o 24 horas son suyos—, y `ValueRow` solo sabe recibir texto ya formateado.
struct AuditFactRow: View {

    let fact: AuditFact

    var body: some View {
        LabeledContent {
            Group {
                switch fact.value {
                case .text(let text):
                    Text(text)
                case .instant(let date):
                    Text(date, format: Date.FormatStyle.dayAndTime.second())
                }
            }
            .font(.rowValue)
            .foregroundStyle(Color(.neutral))
        } label: {
            Text(fact.label)
                .font(.cardBody)
        }
    }
}
