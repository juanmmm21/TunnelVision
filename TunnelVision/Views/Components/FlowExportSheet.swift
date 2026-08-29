import SwiftUI

/// Lo que se enseña con el export ya escrito y **antes** de compartirlo (`docs/ux/screens.md`,
/// pantalla *Captures*).
///
/// Existe porque compartir saca datos del dispositivo y eso no se hace sin decir antes qué se va a
/// sacar: cuántas conexiones lleva el fichero, cuánto ocupa, que son metadatos y no contenido, y si
/// el tope se dejó fuera parte del historial. Todo eso lo decide `CapturesPresentation`; aquí solo se
/// pinta y se ofrece el `ShareLink`, que es la hoja del sistema.
struct FlowExportSheet: View {

    let summary: FlowExportSummary

    /// Cerrar sin compartir. El fichero se queda en el temporal hasta el siguiente export: quitarlo
    /// aquí correría con la hoja del sistema, que puede estar leyéndolo todavía.
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            // Se desplaza y va sobre el lienzo, igual que la hoja del perfil de la CA: son la misma
            // pieza —qué se va a sacar del dispositivo, y el botón de sacarlo— y con letra de
            // accesibilidad el resumen no cabe en un detent medio.
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.card) {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(summary.title)
                            .font(.cardTitle)

                        Text(summary.detail)
                            .font(.cardBody)
                            .foregroundStyle(Color(.neutral))
                    }

                    Text(CapturesPresentation.exportActionDescription)
                        .font(.supporting)
                        .foregroundStyle(Color(.neutral))
                        .fixedSize(horizontal: false, vertical: true)

                    if let note = summary.truncationNote {
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.supporting)
                            .foregroundStyle(StatusRole.warning.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // El mismo papel que el nombre del perfil de la CA y por lo mismo: es un dato que
                    // el usuario va a buscar en Ficheros, así que se lee carácter a carácter y con el
                    // token neutral, no con un gris terciario del sistema.
                    Text(summary.fileName)
                        .font(.literal)
                        .foregroundStyle(Color(.neutral))

                    ShareLink(item: summary.url) {
                        Label(CapturesPresentation.exportShareTitle, systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    // Por lo mismo que en la hoja del perfil: el relleno por defecto es el acento
                    // global, que en oscuro es la marca clara y dejaba el rótulo blanco sin leerse.
                    .brandProminentButton()
                    .controlSize(.large)
                }
                .padding(Spacing.card)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .screenCanvas()
            .navigationTitle(CapturesPresentation.exportSheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(CommonCopy.done) { onDismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
