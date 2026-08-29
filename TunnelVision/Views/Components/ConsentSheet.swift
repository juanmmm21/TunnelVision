import SwiftUI

/// La hoja de explicación que precede a un diálogo del sistema.
///
/// Existe por una regla dura de `docs/ux/onboarding-and-consent.md`: **explicar antes, nunca
/// después**, y ofrecer siempre un camino para no hacerlo. Es genérica porque el mismo patrón vuelve
/// en el flujo de la CA (M10); aquí la usa el permiso de VPN.
///
/// La copia entera —incluida la de la salida— llega en un `ConsentPresentation`: que la hoja tenga
/// siempre las dos salidas es la regla, y una regla no se afirma sobre un literal escondido en una
/// vista.
struct ConsentSheet: View {

    let presentation: ConsentPresentation
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Se desplaza, como la hoja del perfil de la CA y por lo mismo: con letra de accesibilidad
            // el párrafo no cabe en un detent medio, y aquí lo que no se lee es justo lo que se está
            // consintiendo.
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.card) {
                    Text(presentation.message)
                        .font(.prose)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        // Se cierra antes de actuar: la acción trae el diálogo del sistema por
                        // delante, y dos capas de UI modal encima del usuario a la vez es justo lo que
                        // no queremos.
                        dismiss()
                        onConfirm()
                    } label: {
                        Text(presentation.confirmTitle)
                            .frame(maxWidth: .infinity)
                    }
                    // El relleno es `brandFill` y no el acento global: con el acento, en oscuro este
                    // botón era rótulo blanco sobre cian claro.
                    .brandProminentButton()
                    .controlSize(.large)
                }
                .padding(Spacing.card)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .screenCanvas()
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(presentation.cancelTitle) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

extension ConsentSheet {

    /// La hoja del permiso de VPN, cuya copia decide `ConsentPresentation`.
    static func vpnPermission(onConfirm: @escaping () -> Void) -> ConsentSheet {
        ConsentSheet(presentation: .vpnPermission, onConfirm: onConfirm)
    }
}
