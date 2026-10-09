import SwiftUI

/// Lo que se enseña con el paquete de evidencia ya escrito y **antes** de compartirlo
/// (`docs/ux/audit.md` § *Exporting a session*).
///
/// Es la misma pieza que `FlowExportSheet` —qué se va a sacar del dispositivo, y el botón de
/// sacarlo— con más que decir: de la captura, cuántos paquetes lleva y cuántos le faltan y por
/// qué, que es lo que no se ve abriendo el zip. Qué se dice lo decide `AuditPresentation`; aquí
/// solo se pinta y se ofrece el `ShareLink`.
struct EvidenceExportSheet: View {

    let summary: EvidenceExportSummary

    /// Cerrar sin compartir. El zip se queda en el temporal hasta la siguiente exportación.
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.card) {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(summary.title)
                            .font(.cardTitle)

                        Text(summary.detail)
                            .font(.cardBody)
                            .foregroundStyle(Color(.neutral))
                    }

                    note(summary.contents)

                    VStack(alignment: .leading, spacing: Spacing.close) {
                        ForEach(summary.facts) { fact in
                            AuditFactRow(fact: fact)
                        }
                        note(summary.findingsNote)
                    }

                    capture(summary.capture)

                    // El mismo papel que el nombre del export de conexiones: es lo que el usuario
                    // va a buscar en Ficheros, así que se lee carácter a carácter.
                    Text(summary.fileName)
                        .font(.literal)
                        .foregroundStyle(Color(.neutral))

                    ShareLink(item: summary.url) {
                        Label(AuditPresentation.evidenceShareTitle, systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .brandProminentButton()
                    .controlSize(.large)
                }
                .padding(Spacing.card)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .screenCanvas()
            .navigationTitle(AuditPresentation.evidenceSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            // Opaca: aquí el contenido sí se desliza bajo la barra (`docs/ux/design-system.md`).
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color(.canvas), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(CommonCopy.done) { onDismiss() }
                }
            }
        }
        // Entera desde el principio: lo que hay que leer antes de compartir no cabe en media
        // pantalla, y una hoja a medias dejaría el botón de compartir a la vista y el aviso de la
        // captura debajo del pliegue.
        .presentationDetents([.large])
    }

    /// La captura: el titular con símbolo **y** color, lo que le falta y por qué, y lo que quien
    /// comparte tiene que saber de ella.
    private func capture(_ display: EvidenceCaptureDisplay) -> some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            SectionHeader(AuditPresentation.evidenceCaptureSectionTitle)

            // Un `HStack` y no un `Label`: fuera de una lista el `Label` no alinea un titular de
            // varias líneas con su símbolo.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.close) {
                Image(systemName: display.systemImage)
                    .foregroundStyle(display.role.color)
                    .accessibilityHidden(true)
                Text(display.headline)
                    .font(.cardBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            ForEach(display.details, id: \.self) { detail in
                note(detail)
            }

            note(AuditPresentation.evidenceCleartextCaution)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.supporting)
            .foregroundStyle(Color(.neutral))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
